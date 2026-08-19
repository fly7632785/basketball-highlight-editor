# Windows 一键环境搭建:工具链检测/安装 + Python venv + FFmpeg + 自检。
# 用法:
#   powershell -ExecutionPolicy Bypass -File scripts\setup_windows.ps1
# 可选参数:
#   -SkipToolchain  跳过工具链(VS/Flutter/Python)安装,只做项目内设置
#   -Yes            跳过大体积安装确认(Visual Studio 约 15GB)
param(
    [switch]$SkipToolchain,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path "$PSScriptRoot\..").Path
Set-Location $Root

function Write-Step($msg)  { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Skip($msg)  { Write-Host "    [跳过] $msg" -ForegroundColor DarkGray }
function Write-Warn($msg)  { Write-Host "    [注意] $msg" -ForegroundColor Yellow }

# ─────────────────────────────────────────────────────────────
# 1. 开发者模式(Flutter 插件构建需要符号链接权限)
# ─────────────────────────────────────────────────────────────
Write-Step "检查 Windows 开发者模式"
$devMode = Get-ItemProperty `
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' `
    -ErrorAction SilentlyContinue
if ($devMode -and $devMode.AllowDevelopmentWithoutDevLicense -eq 1) {
    Write-Ok "已开启"
} else {
    Write-Warn "未开启。Flutter 构建 Windows 插件需要符号链接权限,请到:"
    Write-Warn "  设置 -> 隐私和安全性 -> 开发者选项 -> 开发人员模式 打开后重跑本脚本"
    if (-not $Yes) {
        throw "请先开启开发者模式(或以 -Yes 继续,风险自负)"
    }
}

# ─────────────────────────────────────────────────────────────
# 2. 工具链检测与安装
# ─────────────────────────────────────────────────────────────
if ($SkipToolchain) {
    Write-Step "跳过工具链安装(-SkipToolchain)"
} else {
    Write-Step "检查 Visual Studio 2022 (C++ 桌面开发)"
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $hasVs = (Test-Path $vswhere) -and (
        & $vswhere -products '*' `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property displayName 2>$null | Measure-Object).Count -gt 0
    if ($hasVs) {
        Write-Skip "已安装"
    } else {
        if (-not $Yes) {
            $confirm = Read-Host "未安装。现在用 winget 安装 VS 2022 Community + C++ 工作负载吗(约 15GB,20-60 分钟)? [y/N]"
            if ($confirm -notin @('y', 'Y')) { throw "已取消。请手动安装后重跑,或用 -SkipToolchain 跳过" }
        }
        winget install --id Microsoft.VisualStudio.2022.Community --exact `
            --accept-package-agreements --accept-source-agreements `
            --override "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.NativeDesktop --includeRecommended"
        Write-Ok "Visual Studio 安装完成"
    }

    Write-Step "检查 Flutter"
    $flutter = Get-Command flutter -ErrorAction SilentlyContinue
    if (-not $flutter -and (Test-Path 'C:\flutter\bin\flutter.bat')) {
        $env:Path = "C:\flutter\bin;$env:Path"
        $flutter = Get-Command flutter -ErrorAction SilentlyContinue
    }
    if ($flutter) {
        Write-Skip "已安装: $(& flutter --version | Select-Object -First 1)"
    } else {
        Write-Host "    未安装,使用 winget 安装 Flutter..."
        winget install --id Flutter.Flutter --exact `
            --accept-package-agreements --accept-source-agreements
        Write-Warn "安装完成,请重开终端让 PATH 生效后重跑本脚本做后续检查"
        throw "Flutter 刚装好,PATH 需要新终端生效"
    }

    Write-Step "检查 Python 3.12"
    $py = $null
    foreach ($candidate in @(
        "$Root\.venv\Scripts\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe"
    )) {
        if (Test-Path $candidate) { $py = $candidate; break }
    }
    if (-not $py) {
        $pyCmd = Get-Command python -ErrorAction SilentlyContinue
        if ($pyCmd -and ((& python --version 2>$null) -match '3\.12')) { $py = 'python' }
    }
    if ($py) {
        Write-Skip "已安装: $py"
    } else {
        Write-Host "    未安装,使用 winget 安装 Python 3.12..."
        winget install --id Python.Python.3.12 --exact --silent `
            --accept-package-agreements --accept-source-agreements
        $py = "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe"
        Write-Warn "安装完成,建议重开终端后重跑本脚本确认 PATH"
    }
}

# ─────────────────────────────────────────────────────────────
# 3. Python 虚拟环境 + 依赖(含 torch/ultralytics,约 2GB)
# ─────────────────────────────────────────────────────────────
Write-Step "准备 .venv 虚拟环境"
if (Test-Path "$Root\.venv\Scripts\python.exe") {
    Write-Skip ".venv 已存在"
} else {
    $basePy = "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe"
    if (-not (Test-Path $basePy)) { $basePy = 'python' }
    & $basePy -m venv "$Root\.venv"
    Write-Ok ".venv 创建完成"
}

$venvPy = "$Root\.venv\Scripts\python.exe"
Write-Step "安装 Python 依赖(requirements.txt,含 torch 约 2GB)"
& $venvPy -m pip install -q --upgrade pip
& $venvPy -m pip install -q -r "$Root\requirements.txt" -r "$Root\requirements-dev.txt"
if ($LASTEXITCODE -ne 0) { throw "pip install 失败,请检查网络后重跑" }
Write-Ok "依赖安装完成"

# ─────────────────────────────────────────────────────────────
# 4. FFmpeg -> bin/(引擎通过 extraPath 自动发现)
# ─────────────────────────────────────────────────────────────
Write-Step "准备 bin\ffmpeg.exe / ffprobe.exe"
if ((Test-Path "$Root\bin\ffmpeg.exe") -and (Test-Path "$Root\bin\ffprobe.exe")) {
    Write-Skip "bin\ 已就绪"
} else {
    $zip = Join-Path $env:TEMP "ffmpeg-essentials.zip"
    Write-Host "    下载 FFmpeg essentials(约 80MB)..."
    Invoke-WebRequest `
        'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip' `
        -OutFile $zip
    Write-Host "    解压并提取 ffmpeg.exe / ffprobe.exe..."
    $dest = Join-Path $env:TEMP 'ffmpeg-extract'
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Expand-Archive $zip $dest
    New-Item -ItemType Directory -Force -Path "$Root\bin" | Out-Null
    Copy-Item (Get-ChildItem $dest -Recurse -Filter ffmpeg.exe  |
        Select-Object -First 1).FullName "$Root\bin\ffmpeg.exe" -Force
    Copy-Item (Get-ChildItem $dest -Recurse -Filter ffprobe.exe |
        Select-Object -First 1).FullName "$Root\bin\ffprobe.exe" -Force
    Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Write-Ok "bin\ffmpeg.exe + ffprobe.exe 就绪"
}

# ─────────────────────────────────────────────────────────────
# 5. 模型自检(models/bball_model.pt 随 git 分发)
# ─────────────────────────────────────────────────────────────
if (Test-Path "$Root\models\bball_model.pt") {
    Write-Ok "检测模型 models\bball_model.pt 存在"
} else {
    Write-Warn "models\bball_model.pt 缺失(应随 git 仓库分发),请检查 clone 完整性"
}

# ─────────────────────────────────────────────────────────────
# 6. 运行时自检
# ─────────────────────────────────────────────────────────────
Write-Step "运行 check_runtime 自检"
$env:Path = "$Root\bin;$env:Path"
& $venvPy "$Root\scripts\check_runtime.py" --root $Root --python $venvPy
if ($LASTEXITCODE -ne 0) { Write-Warn "自检有失败项,按上面提示处理" }

# ─────────────────────────────────────────────────────────────
# 7. 收尾指引
# ─────────────────────────────────────────────────────────────
Write-Host @"

============================================================
 环境就绪!接下来:
   cd apps\desktop
   flutter pub get
   flutter run -d windows        # 开发调试
   # 或发布构建: flutter build windows --release
============================================================
"@ -ForegroundColor Green
