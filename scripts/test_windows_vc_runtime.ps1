# Exercise packaging with a fake VS layout and deterministic dependency/version results.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'install_windows_vc_runtime.ps1')

function Get-VcRuntimeDependencies($Dumpbin, $Path) {
    switch ([IO.Path]::GetFileName($Path)) {
        'BHE.exe' { 'MSVCP140.dll' }
        'python.exe' { 'vcruntime140.dll' }
        'cv2.pyd' { 'msvcp140_2.dll' }
        'msvcp140_2.dll' { 'msvcp140_1.dll' }
    }
}

function Get-VcRuntimeFileVersion($Path) {
    [version](Get-Content -LiteralPath $Path -Raw)
}

function Assert-PackagingFails($Message) {
    try {
        Install-WindowsVcRuntime -CompilerPath $Compiler -AppDir $App -PythonDir $Python
    } catch {
        if ($_.Exception.Message -notlike $Message) { throw }
        return
    }
    throw "Expected packaging to fail with: $Message"
}

$Temp = Join-Path ([IO.Path]::GetTempPath()) ('bhe-vc-runtime-' + [guid]::NewGuid())
try {
    $Compiler = Join-Path $Temp 'Visual Studio/VC/Tools/MSVC/14.44.35207/bin/Hostx64/x64/cl.exe'
    $Redist = Join-Path $Temp 'Visual Studio/VC/Redist/MSVC/14.44.35211/x64/Microsoft.VC143.CRT'
    $App = Join-Path $Temp 'BHE'
    $Python = Join-Path $Temp 'stage/python'
    $Nested = Join-Path $Python 'Lib/site-packages/torch/lib'
    [void](New-Item -ItemType Directory -Force -Path (Split-Path $Compiler), $Redist, $App, $Nested)
    foreach ($file in @($Compiler, (Join-Path (Split-Path $Compiler) 'dumpbin.exe'),
            (Join-Path $App 'BHE.exe'), (Join-Path $Python 'python.exe'), (Join-Path $Nested 'cv2.pyd'))) {
        [IO.File]::WriteAllText($file, '')
    }
    $required = @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140_2.dll', 'msvcp140_1.dll', 'msvcp140_codecvt_ids.dll')
    $new = '14.44.35211.0'
    $old = '14.29.30135.0'
    $rootCopy = Join-Path $Python 'vcruntime140.dll'
    $nestedCopy = Join-Path $Nested 'msvcp140_codecvt_ids.dll'
    [IO.File]::WriteAllText($rootCopy, $old)
    [IO.File]::WriteAllText($nestedCopy, $old)
    $missing = Join-Path $Redist 'msvcp140_1.dll'
    foreach ($dll in $required + 'concrt140.dll') {
        $path = Join-Path $Redist $dll
        if ($path -ne $missing) { [IO.File]::WriteAllText($path, $new) }
    }

    Assert-PackagingFails '*msvcp140_1.dll*missing*'
    foreach ($version in @($old, '14.44.35206.0')) {
        [IO.File]::WriteAllText($missing, $version)
        Assert-PackagingFails '*msvcp140_1.dll*older*14.44.35207.0*'
    }
    if ((Get-Content $rootCopy -Raw) -ne $old -or (Test-Path (Join-Path $App 'msvcp140.dll'))) {
        throw 'Validation failure changed the staged package'
    }

    [IO.File]::WriteAllText($missing, $new)
    Install-WindowsVcRuntime -CompilerPath $Compiler -AppDir $App -PythonDir $Python
    foreach ($dir in @($App, $Python)) {
        foreach ($dll in $required) {
            if ((Get-Content -LiteralPath (Join-Path $dir $dll) -Raw) -ne $new) { throw "Incorrect $dir/$dll" }
        }
        if (Test-Path (Join-Path $dir 'concrt140.dll')) { throw 'Unused redist was copied' }
    }
    if ((Get-Content -LiteralPath $nestedCopy -Raw) -ne $new) { throw 'Nested runtime was not replaced' }
    Write-Output 'Windows VC runtime: dependency closure, version gates and app-local replacement passed.'
} finally {
    if (Test-Path $Temp) { Remove-Item -LiteralPath $Temp -Recurse -Force }
}
