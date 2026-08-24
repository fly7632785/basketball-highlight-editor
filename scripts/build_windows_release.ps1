# 构建 Windows 发布包:Release exe + runtime,可选打 zip。
# 用法:
#   powershell -File scripts\build_windows_release.ps1 [-Zip] [-PythonRuntime ...] [-Ffmpeg ...] [-Ffprobe ...]
#
# 产物: apps\desktop\build\windows\x64\runner\Release\ (exe 与 runtime\ 同级),
# -Zip 时另存 dist\BHE-windows-x64.zip。
param(
    [switch]$Zip,
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

if ($Zip) {
    $Dist = "$Root\dist"
    New-Item -ItemType Directory -Force -Path $Dist | Out-Null
    Compress-Archive -Force -Path "$ReleaseDir\*" -DestinationPath "$Dist\BHE-windows-x64.zip"
    Write-Host "zip ready: $Dist\BHE-windows-x64.zip"
}

Write-Host "release ready: $ReleaseDir"
