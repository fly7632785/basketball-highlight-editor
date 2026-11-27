# Exercise packaging with a fake VS layout and deterministic dependency/version results.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'install_windows_vc_runtime.ps1')

# Preserve at least the first fixed Pillow release from GHSA-78g4-xqwv-q3g8.
$pillowConstraint = @(Select-String -LiteralPath (Join-Path $PSScriptRoot '../requirements-windows-x64-constraints.txt') `
    -Pattern '^pillow\s*(?:>=|==)\s*(?<version>\d+\.\d+\.\d+)\s*$')
if ($pillowConstraint.Count -ne 1 -or
    [version]($pillowConstraint[0].Matches[0].Groups['version'].Value) -lt [version]'13.0.0') {
    throw 'Windows release must require Pillow 13.0.0 or newer (GHSA-78g4-xqwv-q3g8).'
}

function Get-VcRuntimeDependencies($Dumpbin, $Path) {
    switch ([IO.Path]::GetFileName($Path)) {
        'BHE.exe' { 'MSVCP140.dll' }
        'python.exe' { 'vcruntime140.dll' }
        'cv2.pyd' { 'msvcp140_2.dll' }
        'ffmpeg.exe' { 'msvcp140.dll' }
        'writers.pyd' { 'VCRUNTIME140.dll' }
        '_imaging.pyd' { 'VCRUNTIME140.dll' }
        'no_vc_import.pyd' { 'python311.dll'; 'kernel32.dll' }
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

function Set-TestPeLinkerVersion($Path, [byte]$Minor) {
    $header = [byte[]]::new(0x9c)
    $header[0] = 0x4d
    $header[1] = 0x5a
    $header[0x3c] = 0x80
    $header[0x80] = 0x50
    $header[0x81] = 0x45
    $header[0x98] = 0x0b
    $header[0x99] = 0x02
    $header[0x9a] = 14
    $header[0x9b] = $Minor
    [IO.File]::WriteAllBytes($Path, $header)
}

$Temp = Join-Path ([IO.Path]::GetTempPath()) ('bhe-vc-runtime-' + [guid]::NewGuid())
try {
    $Compiler = Join-Path $Temp 'Visual Studio/VC/Tools/MSVC/14.42.34433/bin/Hostx64/x64/cl.exe'
    $Redist = Join-Path $Temp 'Visual Studio/VC/Redist/MSVC/14.42.34438/x64/Microsoft.VC143.CRT'
    $App = Join-Path $Temp 'BHE'
    $Python = Join-Path $Temp 'stage/python'
    $Nested = Join-Path $Python 'Lib/site-packages/torch/lib'
    $Bin = Join-Path $Temp 'stage/bin'
    $Pandas = Join-Path $Python 'Lib/site-packages/pandas/_libs'
    [void](New-Item -ItemType Directory -Force -Path (Split-Path $Compiler), $Redist, $App, $Nested, $Bin, $Pandas)
    foreach ($file in @($Compiler, (Join-Path (Split-Path $Compiler) 'dumpbin.exe'),
            (Join-Path $App 'BHE.exe'), (Join-Path $Python 'python.exe'), (Join-Path $Nested 'cv2.pyd'))) {
        Set-TestPeLinkerVersion $file 42
    }
    $required = @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140_2.dll', 'msvcp140_1.dll', 'msvcp140_codecvt_ids.dll')
    $new = '14.42.34438.0'
    $old = '14.29.30135.0'
    $newer = '14.44.35211.0'
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
    foreach ($version in @($old, '14.42.34432.0')) {
        [IO.File]::WriteAllText($missing, $version)
        Assert-PackagingFails '*msvcp140_1.dll*older*14.42.34433.0*'
    }
    if ((Get-Content $rootCopy -Raw) -ne $old -or (Test-Path (Join-Path $App 'msvcp140.dll'))) {
        throw 'Validation failure changed the staged package'
    }

    [IO.File]::WriteAllText($missing, $new)
    foreach ($bundled in @($rootCopy, $nestedCopy, (Join-Path $App 'vcruntime140.dll'))) {
        [IO.File]::WriteAllText($bundled, $newer)
        Assert-PackagingFails '*older*14.44.35211.0*Visual Studio Installer*'
        if ((Get-Content -LiteralPath $bundled -Raw) -ne $newer -or (Test-Path (Join-Path $App 'msvcp140.dll'))) {
            throw 'Rejected redist changed the staged package'
        }
        [IO.File]::WriteAllText($bundled, $old)
    }

    $extension = Join-Path $Nested 'cv2.pyd'
    Set-TestPeLinkerVersion $extension 44
    Assert-PackagingFails '*older*14.44.0.0*cv2.pyd*Visual Studio Installer*'
    $ffmpeg = Join-Path $Bin 'ffmpeg.exe'
    Set-TestPeLinkerVersion $ffmpeg 45
    Assert-PackagingFails '*older*14.45.0.0*ffmpeg.exe*Visual Studio Installer*'
    Set-TestPeLinkerVersion $ffmpeg 44

    # Installing the requested redistributable in the same VS instance unblocks the build.
    [IO.File]::WriteAllText($rootCopy, $newer)
    $updatedRedist = $Redist.Replace('14.42.34438', '14.44.35211')
    [void](New-Item -ItemType Directory -Path $updatedRedist -Force)
    foreach ($dll in $required + 'concrt140.dll') {
        [IO.File]::WriteAllText((Join-Path $updatedRedist $dll), $newer)
    }

    # pandas 3.1.1 imports VCRUNTIME140 and requires a newer redist than 14.44.
    $writer = Join-Path $Pandas 'writers.pyd'
    Set-TestPeLinkerVersion $writer 51
    Assert-PackagingFails '*older*14.51.0.0*writers.pyd*Visual Studio Installer*'
    if ((Get-Content -LiteralPath $nestedCopy -Raw) -ne $old -or
        (Test-Path -LiteralPath (Join-Path $App 'msvcp140.dll'))) {
        throw 'Rejected pandas runtime changed the staged package'
    }
    Set-TestPeLinkerVersion $writer 44

    # The official Pillow 13.0.0 wheel imports VCRUNTIME140 and has linker 14.51.
    $imaging = Join-Path $Python '_imaging.pyd'
    Set-TestPeLinkerVersion $imaging 51
    Assert-PackagingFails '*older*14.51.0.0*_imaging.pyd*Visual Studio Installer*'
    # A fixed Pillow built with linker 14.44 can satisfy the same gate.
    Set-TestPeLinkerVersion $imaging 44

    # A newer linker alone does not imply that the PE uses the VC runtime.
    Set-TestPeLinkerVersion (Join-Path $Python 'no_vc_import.pyd') 52
    Install-WindowsVcRuntime -CompilerPath $Compiler -AppDir $App -PythonDir $Python
    foreach ($dir in @($App, $Python)) {
        foreach ($dll in $required) {
            if ((Get-Content -LiteralPath (Join-Path $dir $dll) -Raw) -ne $newer) { throw "Incorrect $dir/$dll" }
        }
        if (Test-Path (Join-Path $dir 'concrt140.dll')) { throw 'Unused redist was copied' }
    }
    if ((Get-Content -LiteralPath $nestedCopy -Raw) -ne $newer) { throw 'Nested runtime was not replaced' }
    $notice = Get-Content -LiteralPath (Join-Path $App 'THIRD_PARTY_NOTICES_VC_RUNTIME.txt') -Encoding UTF8
    $listed = @($notice | Where-Object { $_ -match '^\S+\.dll$' })
    if (Compare-Object ($required | Sort-Object) ($listed | Sort-Object)) { throw 'Notice does not list the packaged DLLs' }
    Write-Output 'Windows VC runtime: dependency closure, version gates and app-local replacement passed.'
} finally {
    if (Test-Path $Temp) { Remove-Item -LiteralPath $Temp -Recurse -Force }
}
