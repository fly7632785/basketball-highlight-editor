# 准备 Windows 发布运行时目录:Python 运行时 + 引擎脚本 + 模型 + ffmpeg。
# 用法:
#   powershell -File scripts\prepare_windows_runtime.ps1 `
#     -PythonRuntime C:\path\to\portable-python `
#     [-Ffmpeg C:\path\to\ffmpeg.exe] [-Ffprobe C:\path\to\ffprobe.exe] `
#     [-OutPath dist\windows-runtime]
#
# PythonRuntime 需为含 python.exe 且已安装 requirements.txt 依赖
# (torch/ultralytics/opencv) 的可携带目录,推荐 python-build-standalone
# 的 cpython-*-windows-x86_64 版本。
param(
    [string]$OutPath = "$PSScriptRoot\..\dist\windows-runtime",
    [Parameter(Mandatory = $true)]
    [string]$PythonRuntime,
    [string]$Ffmpeg,
    [string]$Ffprobe
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path "$PSScriptRoot\..").Path
$Out = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutPath)

if (-not (Test-Path "$PythonRuntime\python.exe")) {
    Write-Error "PythonRuntime must contain python.exe: $PythonRuntime"
}

function Resolve-Tool([string]$Path, [string]$Name) {
    if ($Path -and (Test-Path $Path)) { return (Resolve-Path $Path).Path }
    $fromPath = Get-Command $Name -ErrorAction SilentlyContinue
    if ($fromPath) { return $fromPath.Source }
    Write-Error "$Name not found; pass -$Name explicitly"
}

$Ffmpeg = Resolve-Tool $Ffmpeg 'ffmpeg'
$Ffprobe = Resolve-Tool $Ffprobe 'ffprobe'

if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
New-Item -ItemType Directory -Force -Path `
    "$Out\bin", "$Out\python", "$Out\engine", "$Out\scripts", `
    "$Out\src", "$Out\models", "$Out\docs\architecture" | Out-Null

Copy-Item -Recurse -Force "$PythonRuntime\*" "$Out\python\"
Copy-Item -Recurse -Force "$Root\engine\python" "$Out\engine\"
Copy-Item -Recurse -Force "$Root\scripts\*" "$Out\scripts\"
Copy-Item -Recurse -Force "$Root\src\*" "$Out\src\"
Copy-Item -Force "$Root\models\bball_model.pt" "$Out\models\"
Copy-Item -Force "$Root\docs\architecture\SQLITE_SCHEMA_V1.sql" "$Out\docs\architecture\"
Copy-Item -Force $Ffmpeg "$Out\bin\ffmpeg.exe"
Copy-Item -Force $Ffprobe "$Out\bin\ffprobe.exe"

Write-Host "runtime ready: $Out"
