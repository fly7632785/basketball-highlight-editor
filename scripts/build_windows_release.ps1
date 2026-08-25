# 构建 Windows 发布包:Release exe + runtime,可选打 zip。
# 用法:
#   powershell -File scripts\build_windows_release.ps1 [-Zip] [-Version ...]
#     [-PackageOut ...] [-PythonRuntime ...] [-Ffmpeg ...] [-Ffprobe ...]
#
# 产物: apps\desktop\build\windows\x64\runner\Release\ (exe 与 runtime\ 同级),
# -Zip 时另存带版本号的 dist\BHE-windows-x64-v<Version>.zip 和 SHA-256 文件。
param(
    [switch]$Zip,
    [string]$Version = "local",
    [string]$PackageOut,
    [string]$PythonRuntime,
    [string]$Ffmpeg,
    [string]$Ffprobe,
    [string]$RuntimeOut = "$PSScriptRoot\..\dist\windows-runtime",
    [string]$Flutter = "flutter"
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path "$PSScriptRoot\..").Path

$prepareArgs = @{ OutPath = $RuntimeOut }
if ($PythonRuntime) { $prepareArgs.PythonRuntime = $PythonRuntime }
if ($Ffmpeg) { $prepareArgs.Ffmpeg = $Ffmpeg }
if ($Ffprobe) { $prepareArgs.Ffprobe = $Ffprobe }
& powershell -File "$Root\scripts\prepare_windows_runtime.ps1" @prepareArgs

Push-Location "$Root\apps\desktop"
try {
    & $Flutter build windows --release
    if ($LASTEXITCODE -ne 0) { Write-Error "flutter build windows failed" }
} finally {
    Pop-Location
}

$ReleaseDir = "$Root\apps\desktop\build\windows\x64\runner\Release"
if (-not (Test-Path "$ReleaseDir\BHE.exe")) {
    Write-Error "BHE.exe not found in $ReleaseDir"
}

$AppRuntime = "$ReleaseDir\runtime"
if (Test-Path $AppRuntime) { Remove-Item -Recurse -Force $AppRuntime }
Copy-Item -Recurse -Force "$RuntimeOut" $AppRuntime

& "$AppRuntime\python\python.exe" "$AppRuntime\scripts\check_runtime.py" `
    --root "$AppRuntime" `
    --python "$AppRuntime\python\python.exe" `
    --ffmpeg "$AppRuntime\bin\ffmpeg.exe" `
    --ffprobe "$AppRuntime\bin\ffprobe.exe" `
    --model "$AppRuntime\models\bball_model.pt"
if ($LASTEXITCODE -ne 0) { Write-Error "runtime check failed" }

if ($Zip -or $PackageOut) {
    $Dist = "$Root\dist"
    New-Item -ItemType Directory -Force -Path $Dist | Out-Null
    if (-not $PackageOut) {
        $PackageOut = "$Dist\BHE-windows-x64-v$Version.zip"
    } elseif (-not [System.IO.Path]::IsPathRooted($PackageOut)) {
        $PackageOut = Join-Path $Root $PackageOut
    }
    $PackageDirectory = Split-Path -Parent $PackageOut
    New-Item -ItemType Directory -Force -Path $PackageDirectory | Out-Null
    if (Test-Path $PackageOut) { Remove-Item -Force $PackageOut }

    # Put the application inside one top-level directory. Without this
    # staging directory, extracting the zip scatters BHE.exe and runtime\
    # into the user's current folder.
    $PackageRoot = Join-Path ([System.IO.Path]::GetTempPath()) "bhe-package-$PID"
    $PackageAppRoot = Join-Path $PackageRoot "BHE"
    if (Test-Path $PackageRoot) { Remove-Item -Recurse -Force $PackageRoot }
    New-Item -ItemType Directory -Force -Path $PackageAppRoot | Out-Null
    try {
        Copy-Item -Recurse -Force "$ReleaseDir\*" $PackageAppRoot
        Compress-Archive -Force -Path $PackageAppRoot -DestinationPath $PackageOut
    } finally {
        if (Test-Path $PackageRoot) { Remove-Item -Recurse -Force $PackageRoot }
    }
    $Hash = (Get-FileHash -Algorithm SHA256 -Path $PackageOut).Hash.ToLowerInvariant()
    $HashFile = "$PackageOut.sha256"
    "$Hash  $([System.IO.Path]::GetFileName($PackageOut))" | Set-Content -Encoding ascii -NoNewline $HashFile
    Write-Host "zip ready: $PackageOut"
    Write-Host "sha256 ready: $HashFile"
}

Write-Host "release ready: $ReleaseDir"
