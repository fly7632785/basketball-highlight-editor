function Get-VcRuntimeDependencies([string]$Dumpbin, [string]$Path) {
    $output = & $Dumpbin /nologo /dependents $Path
    if ($LASTEXITCODE -ne 0) { throw "dumpbin failed for $Path (exit $LASTEXITCODE)" }
    $output | ForEach-Object { $_.Trim() }
}

function Get-VcRuntimeFileVersion([string]$Path) {
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    [version]::new($info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart)
}

function Install-WindowsVcRuntime([string]$CompilerPath, [string]$AppDir, [string]$PythonDir) {
    # Use the VS instance that compiled BHE, even if several are installed.
    if ($CompilerPath -notmatch '^(?<vc>.+[/\\]VC)[/\\]Tools[/\\]MSVC[/\\](?<version>14\.\d+\.\d+)[/\\]bin[/\\]Host\w+[/\\]x64[/\\]cl\.exe$' -or
        -not (Test-Path -LiteralPath $CompilerPath -PathType Leaf)) {
        throw "Cannot locate the Visual Studio x64 toolset from: $CompilerPath"
    }
    $minimum = [version]'14.40.33816.0'  # VS 2022 17.10 introduced constexpr mutex initialization.
    $toolset = [version]($Matches.version + '.0')
    if ($toolset -gt $minimum) { $minimum = $toolset }
    $redistRoot = Join-Path $Matches.vc 'Redist/MSVC'
    $redist = Get-ChildItem -LiteralPath $redistRoot -Directory |
        Where-Object { $_.Name -match '^14\.\d+\.\d+(?:\.\d+)?$' } |
        Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    if (-not $redist) { throw "Visual Studio VC redistributable directory is missing under $redistRoot" }
    $redistX64 = Join-Path $redist.FullName 'x64'
    $crt = Get-ChildItem -LiteralPath $redistX64 -Directory -Filter 'Microsoft.VC14*.CRT' | Select-Object -First 1
    if (-not $crt) { throw "Visual Studio x64 CRT directory is missing under $redistX64" }
    $dumpbin = Join-Path (Split-Path -Parent $CompilerPath) 'dumpbin.exe'
    if (-not (Test-Path -LiteralPath $dumpbin -PathType Leaf)) { throw "dumpbin is missing: $dumpbin" }

    $vcDll = '^(?:msvcp140(?:_\w+)?|vcruntime140(?:_\w+)?|concrt140|vcomp140)\.dll$'
    $pythonFiles = @(Get-ChildItem -LiteralPath $PythonDir -Recurse -File -Force)
    $bundledVc = @($pythonFiles | Where-Object { $_.Name -match $vcDll })
    $binaries = @(Get-ChildItem -LiteralPath $AppDir -File -Force) + $pythonFiles
    # Flutter's baseline and PyTorch's explicit Windows DLL loads.
    $required = @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll') + @($bundledVc.Name)
    foreach ($binary in $binaries) {
        if ($binary.Extension -in '.exe', '.dll', '.pyd' -and $binary.Name -notmatch $vcDll) {
            $required += @(Get-VcRuntimeDependencies $dumpbin $binary.FullName | Where-Object { $_ -match $vcDll })
        }
    }

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
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Required $name is missing: $source" }
        $version = Get-VcRuntimeFileVersion $source
        if ($version -lt $minimum) { throw "$name is older than required ($version < $minimum): $source" }
        $sources[$name] = $source
        Write-Host "Windows VC runtime: $name $version ($source)"
        foreach ($dependency in (Get-VcRuntimeDependencies $dumpbin $source | Where-Object { $_ -match $vcDll })) {
            $pending.Enqueue($dependency)
        }
    }

    foreach ($name in ($sources.Keys | Sort-Object)) {
        Copy-Item -LiteralPath $sources[$name] -Destination (Join-Path $AppDir $name) -Force
        Copy-Item -LiteralPath $sources[$name] -Destination (Join-Path $PythonDir $name) -Force
    }
    # Extensions can explicitly load DLLs from their own directory (e.g. torch/lib).
    $pythonRoot = (Get-Item -LiteralPath $PythonDir).FullName
    foreach ($old in $bundledVc) {
        if ($old.DirectoryName -ne $pythonRoot) {
            Copy-Item -LiteralPath $sources[$old.Name] -Destination $old.FullName -Force
        }
    }
}
