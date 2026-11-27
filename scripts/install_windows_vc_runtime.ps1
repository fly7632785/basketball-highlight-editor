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

function Install-WindowsVcRuntime([string]$CompilerPath, [string]$AppDir, [string]$PythonDir) {
    # Use the VS instance that compiled BHE, even if several are installed.
    if ($CompilerPath -notmatch '^(?<vc>.+[/\\]VC)[/\\]Tools[/\\]MSVC[/\\](?<version>14\.\d+\.\d+)[/\\]bin[/\\]Host\w+[/\\]x64[/\\]cl\.exe$' -or
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
    $redistRoot = Join-Path $Matches.vc 'Redist/MSVC'
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

    $installHint = "Update the Windows build runner or use Visual Studio Installer to install x64 C++ redistributable files version $minimum or newer in the Visual Studio instance used to build BHE ($redistRoot)."
    $redist = if (Test-Path -LiteralPath $redistRoot -PathType Container) {
        Get-ChildItem -LiteralPath $redistRoot -Directory |
            Where-Object { $_.Name -match '^14\.\d+\.\d+(?:\.\d+)?$' } |
            Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    }
    if (-not $redist) { throw "Visual Studio VC redistributable directory is missing. $installHint" }
    $redistX64 = Join-Path $redist.FullName 'x64'
    $crt = if (Test-Path -LiteralPath $redistX64 -PathType Container) {
        Get-ChildItem -LiteralPath $redistX64 -Directory -Filter 'Microsoft.VC14*.CRT' | Select-Object -First 1
    }
    if (-not $crt) { throw "Visual Studio x64 CRT directory is missing under $redistX64. $installHint" }

    # Inspect the selected redist DLLs too, to include their own VC dependencies.
    $pending = [Collections.Generic.Queue[string]]::new()
    foreach ($name in ($required | Sort-Object -Unique)) { $pending.Enqueue($name) }
    $sources = @{}
    while ($pending.Count) {
        $name = $pending.Dequeue().ToLowerInvariant()
        if ($sources.ContainsKey($name)) { continue }
        $source = Join-Path $crt.FullName $name
        if ($name -eq 'vcomp140.dll') {
            $source = Join-Path $redistX64 ($crt.Name -replace '\.CRT$', '.OpenMP')
            $source = Join-Path $source $name
        }
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Required $name is missing: $source. $installHint" }
        $version = Get-VcRuntimeFileVersion $source
        if ($version -lt $minimum) {
            throw "$name is older than required ($version < $minimum from $minimumSource): $source. $installHint"
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
