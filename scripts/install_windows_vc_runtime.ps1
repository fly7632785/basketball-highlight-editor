function Get-VcRuntimeDependencies([string]$Dumpbin, [string]$Path) {
    $output = & $Dumpbin /nologo /dependents $Path
    if ($LASTEXITCODE -ne 0) { throw "dumpbin failed for $Path (exit $LASTEXITCODE)" }
    $output | ForEach-Object { $_.Trim() }
}

function Get-VcRuntimeFileVersion([string]$Path) {
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    [version]::new($info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart)
}

function Get-VcRuntimeLinkerVersion([string]$Path) {
    $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($Path))
    try {
        # The DOS header points to the PE signature, then a 20-byte COFF header.
        $reader.BaseStream.Position = 0x3c
        $reader.BaseStream.Position = $reader.ReadUInt32()
        if ($reader.ReadUInt32() -ne 0x4550) { throw "Invalid PE signature: $Path" }
        $reader.BaseStream.Position += 20
        if ($reader.ReadUInt16() -notin 0x10b, 0x20b) { throw "Invalid PE optional header: $Path" }
        # PE records only linker major/minor; bundled DLL versions retain the patch level.
        $major = $reader.ReadByte()
        $minor = $reader.ReadByte()
        if ($major -eq 14) { [version]::new($major, $minor, 0, 0) }
    } finally {
        $reader.Dispose()
    }
}

function Save-WindowsVcRedistributable([string]$Uri, [string]$OutFile, [int]$TimeoutSeconds = 90) {
    $timeout = @{ TimeoutSec = $TimeoutSeconds }
    if ($PSVersionTable.PSVersion -ge [version]'7.4') {
        $timeout.OperationTimeoutSeconds = $TimeoutSeconds
    }

    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -ErrorAction Stop @timeout
            return
        } catch {
            $exception = $_.Exception
            $response = $exception.PSObject.Properties['Response']
            $status = if ($response -and $response.Value) { [int]$response.Value.StatusCode } else { 0 }
            $retry = $status -eq 429 -or ($status -ge 500 -and $status -lt 600)
            if ($status -eq 0) {
                # Windows PowerShell reports WebExceptionStatus; PowerShell 7 can wrap TimeoutException.
                $retry = $_.CategoryInfo.Category -eq [Management.Automation.ErrorCategory]::OperationTimeout
                while ($exception -and -not $retry) {
                    $retry = $exception -is [TimeoutException] -or
                        ($exception -is [Net.WebException] -and $exception.Status -eq [Net.WebExceptionStatus]::Timeout)
                    $exception = $exception.InnerException
                }
            }
            if (-not $retry) { throw }
            if ($attempt -eq $maxAttempts) {
                throw "Microsoft VC redistributable download failed after $attempt attempts. $($_.Exception.Message)"
            }
            Write-Warning "Microsoft VC redistributable download attempt $attempt of $maxAttempts failed. $($_.Exception.Message) Retrying."
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
}

function Export-WindowsVcBurnContainer([string]$Installer, [string]$Cabinet) {
    $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($Installer))
    try {
        $reader.BaseStream.Position = 0x3c
        $peOffset = $reader.ReadUInt32()
        $reader.BaseStream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x4550) { throw 'Invalid redistributable PE signature.' }
        $reader.BaseStream.Position = $peOffset + 6
        $sectionCount = $reader.ReadUInt16()
        $reader.BaseStream.Position = $peOffset + 20
        $sectionTable = $peOffset + 24 + $reader.ReadUInt16()
        for ($i = 0; $i -lt $sectionCount; $i++) {
            $section = $sectionTable + 40 * $i
            $reader.BaseStream.Position = $section
            if ([Text.Encoding]::ASCII.GetString($reader.ReadBytes(8)) -ne '.wixburn') { continue }
            $reader.BaseStream.Position = $section + 20
            $reader.BaseStream.Position = $reader.ReadUInt32()
            if ($reader.ReadUInt32() -ne 0x00f14300 -or $reader.ReadUInt32() -ne 2) {
                throw 'Unsupported WiX Burn header.'
            }

            # WiX Burn v2 stores the stub, original signature and CAB sizes in .wixburn.
            $reader.BaseStream.Position += 16
            $stubSize = $reader.ReadUInt32()
            $reader.BaseStream.Position += 4
            $signatureOffset = $reader.ReadUInt32()
            $signatureSize = $reader.ReadUInt32()
            if ($reader.ReadUInt32() -ne 1 -or $reader.ReadUInt32() -ne 2) {
                throw 'Expected a WiX Burn bundle with a UX cabinet and one attached cabinet.'
            }
            $uxSize = $reader.ReadUInt32()
            $attachedSize = $reader.ReadUInt32()
            $reader.BaseStream.Position = if ($signatureOffset) { $signatureOffset + $signatureSize } else { $stubSize + $uxSize }
            $attached = $reader.ReadBytes($attachedSize)
            if ($attached.Length -ne $attachedSize -or $attached.Length -lt 4 -or
                [Text.Encoding]::ASCII.GetString($attached, 0, 4) -ne 'MSCF') {
                throw 'Invalid attached WiX Burn cabinet.'
            }
            [IO.File]::WriteAllBytes($Cabinet, $attached)
            return
        }
        throw 'Redistributable is missing its .wixburn section.'
    } finally {
        $reader.Dispose()
    }
}

function Expand-WindowsVcCabinet([string]$Cabinet, [string]$Directory) {
    & (Join-Path $env:SystemRoot 'System32/expand.exe') $Cabinet '-F:*' $Directory | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Cabinet extraction failed for $Cabinet (exit $LASTEXITCODE)." }
}

function Get-PinnedWindowsVcRuntime([string]$Workspace) {
    # Microsoft Visual C++ v14 x64 Redistributable, 14.52.37029.0.
    $uri = 'https://download.visualstudio.microsoft.com/download/pr/78d061c5-9ef3-42ab-98ed-3309d1095dc4/9C02C9ED120F671B900E6B9471D890E3B2414117A7E53F4AE2E855466FA2B7C9/VC_redist.x64.exe'
    $installer = Join-Path $Workspace 'VC_redist.x64.exe'
    Save-WindowsVcRedistributable -Uri $uri -OutFile $installer
    if ((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash -ne '9c02c9ed120f671b900e6b9471d890e3b2414117a7e53f4ae2e855466fa2b7c9') {
        throw 'Microsoft VC_redist.x64.exe SHA-256 mismatch.'
    }

    $layout = Join-Path $Workspace 'layout'
    $payload = Join-Path $Workspace 'payload'
    [void](New-Item -ItemType Directory -Path $layout, $payload)
    try {
        # Expand the verified bundle's container directly. Burn's payloads may have opaque names.
        $bundle = Join-Path $Workspace 'attached.cab'
        Export-WindowsVcBurnContainer -Installer $installer -Cabinet $bundle
        Expand-WindowsVcCabinet -Cabinet $bundle -Directory $layout
        $cabinetHash = '596629040fda9c7eb2b15d809199bf691e7a61d12e8e400f2e94e3871866e9a3'
        $cabinets = @(Get-ChildItem -LiteralPath $layout -Recurse -Force -File | Where-Object {
            (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash -eq $cabinetHash
        })
        if ($cabinets.Count -ne 1) {
            throw "Expected one SHA-256 match for the Microsoft x64 minimum-runtime cabinet, found $($cabinets.Count)."
        }
        $cabinet = Join-Path $Workspace 'x64-runtime.cab'
        Copy-Item -LiteralPath $cabinets[0].FullName -Destination $cabinet
        Expand-WindowsVcCabinet -Cabinet $cabinet -Directory $payload

        $files = @{}
        foreach ($file in (Get-ChildItem -LiteralPath $payload -File -Filter '*.dll_amd64')) {
            $files[($file.Name -replace '_amd64$', '')] = $file.FullName
        }
        if (-not ($files.ContainsKey('vcruntime140.dll') -and $files.ContainsKey('msvcp140.dll'))) {
            throw 'The verified runtime cabinet did not extract vcruntime140.dll and msvcp140.dll.'
        }
        return $files
    } catch {
        Write-Host "Microsoft redistributable extraction tree ($Workspace):"
        Get-ChildItem -LiteralPath $Workspace -Recurse -Force | ForEach-Object {
            $entry = $_.FullName.Substring($Workspace.Length + 1)
            if ($_.PSIsContainer) { Write-Host "  $entry/" } else { Write-Host "  $entry ($($_.Length) bytes)" }
        }
        throw
    }
}

function Install-WindowsVcRuntime([string]$CompilerPath, [string]$AppDir, [string]$PythonDir) {
    $workspace = Join-Path ([IO.Path]::GetTempPath()) ('bhe-vc-redist-' + [guid]::NewGuid())
    try {
        [void](New-Item -ItemType Directory -Path $workspace)
        $redistFiles = Get-PinnedWindowsVcRuntime $workspace
        Copy-WindowsVcRuntime -CompilerPath $CompilerPath -AppDir $AppDir -PythonDir $PythonDir -RedistFiles $redistFiles
    } finally {
        if (Test-Path -LiteralPath $workspace) { Remove-Item -LiteralPath $workspace -Recurse -Force }
    }
}

function Copy-WindowsVcRuntime([string]$CompilerPath, [string]$AppDir, [string]$PythonDir, [hashtable]$RedistFiles) {
    # Use the toolset that compiled BHE to determine its minimum runtime version.
    if ($CompilerPath -notmatch '^.+[/\\]VC[/\\]Tools[/\\]MSVC[/\\](?<version>14\.\d+\.\d+)[/\\]bin[/\\]Host\w+[/\\]x64[/\\]cl\.exe$' -or
        -not (Test-Path -LiteralPath $CompilerPath -PathType Leaf)) {
        throw "Cannot locate the Visual Studio x64 toolset from: $CompilerPath"
    }
    $minimum = [version]'14.40.33816.0'  # VS 2022 17.10 introduced constexpr mutex initialization.
    $minimumSource = 'the constexpr mutex compatibility floor'
    $toolset = [version]($Matches.version + '.0')
    if ($toolset -gt $minimum) {
        $minimum = $toolset
        $minimumSource = 'the BHE compiler'
    }
    $dumpbin = Join-Path (Split-Path -Parent $CompilerPath) 'dumpbin.exe'
    if (-not (Test-Path -LiteralPath $dumpbin -PathType Leaf)) { throw "dumpbin is missing: $dumpbin" }

    $vcDll = '^(?:msvcp140(?:_\w+)?|vcruntime140(?:_\w+)?|concrt140|vcomp140)\.dll$'
    $appFiles = foreach ($entry in (Get-ChildItem -LiteralPath $AppDir -Force)) {
        if (!$entry.PSIsContainer) { $entry }
        # The previous runtime directory is replaced by the newly staged one.
        elseif ($entry.Name -ne 'runtime') { Get-ChildItem -LiteralPath $entry.FullName -Recurse -File -Force }
    }
    $packageFiles = @($appFiles) + @(Get-ChildItem -LiteralPath (Split-Path -Parent $PythonDir) -Recurse -File -Force)
    $bundledVc = @($packageFiles | Where-Object { $_.Name -match $vcDll })
    foreach ($bundled in $bundledVc) {
        $version = Get-VcRuntimeFileVersion $bundled.FullName
        if ($version -le [version]'0.0.0.0') { throw "Cannot read existing VC runtime version: $($bundled.FullName)" }
        if ($version -gt $minimum) {
            $minimum = $version
            $minimumSource = "bundled $($bundled.FullName)"
        }
    }
    # Flutter's baseline and PyTorch's explicit Windows DLL loads.
    $required = @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll') + @($bundledVc.Name)
    foreach ($binary in $packageFiles) {
        if ($binary.Extension -in '.exe', '.dll', '.pyd' -and $binary.Name -notmatch $vcDll) {
            $imports = @(Get-VcRuntimeDependencies $dumpbin $binary.FullName | Where-Object { $_ -match $vcDll })
            $required += $imports
            if (-not ($imports -match '^(?:msvcp|vcruntime)140')) { continue }
            $version = Get-VcRuntimeLinkerVersion $binary.FullName
            if ($version -gt $minimum) {
                $minimum = $version
                $minimumSource = "the linker version of $($binary.FullName)"
            }
        }
    }

    # Inspect the selected redist DLLs too, to include their own VC dependencies.
    $pending = [Collections.Generic.Queue[string]]::new()
    foreach ($name in ($required | Sort-Object -Unique)) { $pending.Enqueue($name) }
    $sources = @{}
    while ($pending.Count) {
        $name = $pending.Dequeue().ToLowerInvariant()
        if ($sources.ContainsKey($name)) { continue }
        $source = $RedistFiles[$name]
        if (-not $source -or -not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Required $name is missing from the pinned Microsoft x64 redistributable."
        }
        $version = Get-VcRuntimeFileVersion $source
        if ($version -lt $minimum) {
            throw "$name is older than required ($version < $minimum from $minimumSource): $source. Update the pinned Microsoft x64 redistributable to version $minimum or newer."
        }
        $sources[$name] = $source
        Write-Host "Windows VC runtime: $name $version ($source)"
        foreach ($dependency in (Get-VcRuntimeDependencies $dumpbin $source | Where-Object { $_ -match $vcDll })) {
            $pending.Enqueue($dependency)
        }
    }

    $names = @($sources.Keys | Sort-Object)
    foreach ($name in $names) {
        Copy-Item -LiteralPath $sources[$name] -Destination (Join-Path $AppDir $name) -Force
        Copy-Item -LiteralPath $sources[$name] -Destination (Join-Path $PythonDir $name) -Force
    }
    # Extensions can explicitly load DLLs from their own directory (e.g. torch/lib).
    $rootDirs = @((Get-Item -LiteralPath $AppDir).FullName, (Get-Item -LiteralPath $PythonDir).FullName)
    foreach ($old in $bundledVc) {
        if ($old.DirectoryName -notin $rootDirs) {
            Copy-Item -LiteralPath $sources[$old.Name] -Destination $old.FullName -Force
        }
    }

    $notice = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../docs/WINDOWS_VC_RUNTIME_NOTICE.txt') -Raw -Encoding UTF8
    $noticePath = Join-Path (Get-Item -LiteralPath $AppDir).FullName 'THIRD_PARTY_NOTICES_VC_RUNTIME.txt'
    [IO.File]::WriteAllLines($noticePath, [string[]](@($notice.TrimEnd(), '') + $names), [Text.UTF8Encoding]::new($false))
}
