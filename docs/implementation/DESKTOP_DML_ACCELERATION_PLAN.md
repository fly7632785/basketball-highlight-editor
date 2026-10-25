# 桌面端 DirectML 推理加速实施计划

> 目标：Windows 桌面端的 YOLO 推理从 CPU 切到 GPU（DirectML），并保持 CPU 路径与原有设备探测行为不变。
> 范围：**只新增 DirectML**。CUDA 相关只有原仓库 `select_device()` 里那行 `torch.cuda.is_available()`
> 探测（本版把它搬进 `inference.py`），不含任何 CUDA 版 torch 的安装、打包或下载。
> 前置实测：`performance-analysis.md`、`gpu-accel-pack.md`（工作区根目录）。
> 本文是实施计划；实现进度回填到最后一节。

## 1. 目标与非目标

**目标**

1. Windows 上用 `onnxruntime-directml` 跑检测，`device="dml"`，单张 ≈ 3 ms（CPU 12 ms）。
2. 后端可切换：`auto | cpu | cuda | mps | dml`，默认 `auto`；不可用时自动降级，绝不因加速包缺失而失败。
3. 粗扫 / 精筛 / 篮筐复核三个阶段的检测结果与现有 CPU 路径**在同一容差内等价**（检测数量逐帧一致，候选集合一致）。
4. 打包侧只增加 24 MB（`onnxruntime-directml` wheel）+ 12 MB（动态 batch ONNX），不改变 macOS / 移动端构建。

**非目标**

- 不把 Python 引擎整体换成 Rust runtime（那是另一个量级的改动）。
- 不改候选生成、评分、判定阈值等算法逻辑。
- 不做 macOS CoreML 桌面化（macOS 继续走 torch MPS，本来就可用）。
- 不删除 torch 依赖（CPU / MPS / 用户自装 CUDA 的那台机器仍靠它）。
- **不引入 CUDA 版 torch**：不装、不打包、不做可选下载包。发布链路里 `requirements.txt` 装到的
  就是 CPU 版 torch，`torch.cuda.is_available()` 恒为 `False`，`cuda` 分支在打包环境里不会命中；
  保留它只是为了不改变"开发者自己装了 CUDA torch 时仍然走 GPU"这一原仓库既有行为。

## 2. 已确认的实测事实（本机：9800X3D + RTX 4070 SUPER）

| 事实 | 数值 | 影响 |
|---|---|---|
| ORT-DirectML wheel | 24 MB（安装 ≈ 60 MB） | 可以直接打进 Windows 包，不必做"可选下载" |
| DML 推理（dynamic batch） | batch 1 = **2.88 ms/img**；2 = 13.9；4 = 7.67；8 = 4.62；16 = 3.00 | **DML 路径必须按单张喂**，照搬 torch 的 batch=8 反而慢 60% |
| torch CUDA | batch 8 = 1.95 ms/img | 保留为更高优先级（若用户装了 CUDA torch） |
| torch CPU | 12.0 ms/img | 作为最终回退 |
| PT 与 ONNX 同帧输出 | 完全一致（hoop 0.895 / ball 0.792） | 精度风险低，但需逐帧回归 |
| 现有导出脚本 | `dynamic=False`（静态 batch=1） | DML 跑 batch>1 会报 `Got: 16 Expected: 1`，必须支持动态导出 |
| 移动端 iOS/Android | 已各自走 CoreML / QNN·NNAPI | 本方案只动桌面 Python 引擎，移动端不受影响 |

## 3. 架构

### 3.1 新增模块

```
src/basketball_highlight/
├── onnx_detector.py     # OnnxDetector：ORT 会话 + letterbox + decode + class-aware NMS
└── inference.py         # 后端解析：device 选择、模型路径解析、load_detector()
```

**`onnx_detector.py`** 提供与 `ultralytics.YOLO.predict()` 兼容的返回值，使四个调用点零改动：

```python
class Box:            # 兼容 box.cls[0] / box.conf[0] / box.xyxy[0].tolist()
class Result:         # 兼容 result.boxes / result.names
class OnnxDetector:
    def __init__(self, onnx_path, device="dml", provider_options=None)
    def predict(self, images, conf=0.25, iou=0.7, imgsz=640, max_det=300,
                agnostic_nms=False, batch=1, verbose=False) -> list[Result]
```

- 预处理：letterbox（保持长宽比、pad 114、`INTER_LINEAR`）→ BGR→RGB → `/255` → CHW，与 `ultralytics(rect=False)` 对齐；
- 后处理：输出 `(N, 4+nc, A)` 转置，`argmax` 取类别、逐类 NMS（IoU 0.7）、`max_det 300`、坐标反 letterbox；
- 内部按 `max_batch` 分块：DML 固定 1，CPU 8；
- 直接复用 `scripts/compare_pt_onnx_frame.py` 已验证的 decode 语义（那里已经和 PT 对齐过）。

**`inference.py`**：

```python
def resolve_device(requested: str, model_path: Path) -> str      # auto → cuda > dml > cpu
def backend_status() -> dict                                     # 供日志/诊断/UI
def load_detector(model_path: Path, device: str)                 # → YOLO 或 OnnxDetector
```

`auto` 的判定顺序：`torch.cuda.is_available()` → `onnxruntime` 含 `DmlExecutionProvider` 且同名 `.onnx` 存在 → `mps` → `cpu`。

### 3.2 接线点（改动最小化）

| 文件 | 改动 |
|---|---|
| `scripts/scan_video.py` | `load_yolo_model` 内部改调 `inference.load_detector`；`--device` 增加 `dml` |
| `scripts/refine_candidates.py` | `scan_window` 不变（仍调 `model.predict`），仅模型对象换成适配层 |
| `scripts/refine_dynamic_candidates.py` | 同上；`--device` 增加 `dml` |
| `scripts/verify_rim_crossing.py` | 模型加载走 `load_detector`；`--device` 增加 `dml`；batch 按后端取 |
| `scripts/detect_auto_roi.py` | `select_device` 增 `cuda/dml` 分支（只有 12 帧，优先级低） |
| `engine/.../adapters/analysis.py` | `build_pipeline_commands(device=...)` 给三个阶段透传 `--device` |
| `engine/.../service.py` | 读 `payload["device"]`（默认 `auto`），写进 analysis_parameters 与 checkpoint，日志记录实际后端 |
| `scripts/export_mobile_model.py` | 增加 `--dynamic` / `--batch`（默认保持现状，不影响移动端） |
| `requirements-dml.txt` | 新增 `onnxruntime-directml>=1.20`（仅 Windows） |
| `scripts/prepare_windows_runtime.ps1` | 可选安装 DML 依赖 + 导出动态 ONNX + 一起拷进 runtime |
| `scripts/check_runtime.py` | 增加"加速后端可用性"报告（不阻塞） |

### 3.3 模型文件

- `models/bball_model.pt`（现有，6 MB）→ torch CPU/CUDA/MPS 用。
- `models/bball_model.onnx`（新增，≈12 MB，**dynamic batch**）→ ORT DML/CPU 用；`.gitignore` 已忽略 `models/*.onnx`，构建时生成。
- 解析规则：`device in {"dml"}` 时找 `model_path.with_suffix(".onnx")`；缺失则回落 `cpu` 并在日志里说明。

## 4. 分阶段实施

### P0 核心（本次必做）

1. `onnx_detector.py` + `inference.py`。
2. `export_mobile_model.py` 支持 `--dynamic/--batch`，本地导出 `models/bball_model.onnx`。
3. 三个推理脚本接线 + `--device` 扩展。
4. 单元测试：letterbox / decode / NMS / device 解析 / 适配层形状兼容。
5. 端到端验证（本机）：`test-video.mov` 跑三阶段，DML vs CPU 逐帧比对 + 耗时。

### P1 引擎与打包

6. `analysis.py` / `service.py` 透传 device，日志与 checkpoint 记录。
7. `requirements-dml.txt`、`prepare_windows_runtime.ps1`、`check_runtime.py`。
8. 回归：`pytest`（基线 307 passed / 8 skipped）+ `check_runtime.py`。

### P2 收尾（可后置）

9. UI 上展示"当前推理后端"（引擎状态里已有 device 日志通道）。
10. 用 40 分钟真实比赛复测（长视频的候选数放大效应）。

## 5. 验收标准

| 项 | 标准 |
|---|---|
| 功能 | `--device dml` 能跑通三个阶段；`--device cpu` 行为与改动前完全一致 |
| 精度 | 粗扫逐帧检测数量一致；精筛 `kept` 数一致；复核 `made/rejected` 一致 |
| 性能 | 6 分钟视频标准模式：CPU ≈104 s → DML 目标 ≤80 s；单张推理 ≤3.5 ms |
| 稳定性 | 无 GPU / 无 DML / 无 onnx 时自动降级，不抛异常 |
| 回归 | `pytest` 与改动前同绿；`check_runtime.py` 通过 |

## 6. 风险与缓解

| 风险 | 缓解 |
|---|---|
| DML 的动态 shape 性能塌陷（batch 2 实测 13.9 ms/img） | 适配层强制单张推理；batch 由后端决定，不听调用方 |
| ONNX 输出格式与 PT 细微差异跨过 conf 阈值 | 用现有 `compare_pt_onnx_frame.py` 做逐帧 box/conf 对比；粗扫全量比对检测数量 |
| 打包时 `onnx` 导出依赖缺失 | `prepare_windows_runtime.ps1` 里导出失败只告警，不阻断（CPU 仍可用） |
| DML 在部分老驱动/虚拟机上不可用 | `resolve_device` 先探测 provider，再试建会话；失败即回落 `cpu` |
| 同一台机器同时有 CUDA torch 与 DML | `auto` 优先 cuda（1.95 ms 更快），dml 作为无 CUDA 时的次优 |

## 7. 明确不做

- 不做 `onnxruntime-gpu`（CUDA EP）：160 MB wheel + 需自备 cuDNN/cuBLAS，体积收益不划算。
- 不做 CUDA torch 增量包：与 DML 的端到端收益几乎相同（67 s vs ~68 s），但体积差 100 倍。
- 不改移动端运行时。

## 8. 实施进度

| # | 任务 | 状态 |
|---|---|---|
| 1 | 计划文档 | ✅ 2026-10-24 |
| 2 | `onnx_detector.py` | ✅ 2026-10-24 |
| 3 | `inference.py` | ✅ 2026-10-24 |
| 4 | 动态 ONNX 导出 | ✅ 2026-10-24 |
| 5 | 三脚本接线 | ✅ 2026-10-24 |
| 6 | 单元测试（15 例） | ✅ 2026-10-24 |
| 7 | 端到端验证 | ✅ 2026-10-24（见 §9） |
| 8 | 引擎透传 + 打包 | ✅ 2026-10-24 |

## 9. 实测结果（2026-10-24，9800X3D + RTX 4070 SUPER，6 分钟 1080p 视频）

| 阶段 | CPU | DirectML | 加速 |
|---|---:|---:|---:|
| 代理生成 | 13.6 s | 13.6 s | — |
| 篮筐粗扫 | 31.7 s（脚本内 28.9） | **13.8 s**（脚本内 12.6） | **2.29×** |
| 候选生成 | 0.8 s | 0.8 s | — |
| 精筛 | 29.2 s（脚本内 28.2） | **22.4 s** | 1.30× |
| 篮筐复核 | 21.7 s（脚本内 20.7） | **14.2 s**（脚本内 13.4） | 1.53× |
| 预览缩略图 | 1.7 s | 1.7 s | — |
| **合计（含自动 ROI）** | **≈104 s** | **≈72 s** | **1.45×** |

等价性（同一视频、同一参数）：

- 粗扫逐帧检测数量**完全一致**：678 ball / 1805 hoop，1789 帧无差异；候选数 23，rim 估计 `center_x=643.04` 一致。
- 精筛 `kept = 18/23` 一致；18 个候选事件时间 17 个完全相同，1 个差 0.01 s（42.64 → 42.63，远小于 300 ms 判定容差）。
- 复核结论逐候选一致：`made 16 / rejected 2`，连 `reason` 字段都一样。
- 同一帧 PT 与 ONNX 输出一致（hoop 0.895 / ball 0.792）；7 帧真实裁剪 15/15 检测在 IoU≥0.9 上配对。

两处与计划不同的实测结论：

1. **DML 必须单张推理**。带真实预处理的每帧成本：batch=1 **4.70 ms**、4 → 10.06、8 → 8.31、16 → 6.57。动态 shape 的小批量在 DML 上会退化，`BACKEND_MAX_BATCH["dml"]=1` 已在代码里固定，调用方传 `--batch 8` 也不会改变这一点。
2. **精筛只提速 1.30×**：它的时间主要花在源视频解码、每个候选重开容器（57 ms + 80 ms）和 net/zone 信号上，推理本来就不到一半。想再快得动结构（合并窗口、按需帧率解码），不是换后端能解决的。

## 10. 改动清单

| 文件 | 说明 |
|---|---|
| `src/basketball_highlight/onnx_detector.py` | 新增：ORT 会话 + letterbox + decode + class-aware NMS，返回结构与 ultralytics 兼容 |
| `src/basketball_highlight/inference.py` | 新增：设备解析（cuda > dml > mps > cpu）、模型路径解析、`load_detector` 工厂、回退与后端状态 |
| `scripts/scan_video.py` | `--device` 增加 `dml`；模型加载走 `load_detector`；`device=` 日志改为回写后的实际后端 |
| `scripts/refine_dynamic_candidates.py` | 同上 |
| `scripts/refine_candidates.py` | 同上（benchmark 用的非动态精筛） |
| `scripts/verify_rim_crossing.py` | 同上；新增 `DML_BATCH=1` |
| `scripts/detect_auto_roi.py` | 同上；去掉直接 import torch/ultralytics |
| `scripts/export_mobile_model.py` | 新增 `--dynamic` / `--batch`，导出时写 `*.onnx.names.json` |
| `engine/.../adapters/analysis.py` | `build_pipeline_commands(device=...)`、`build_rim_check_command(device=...)` |
| `engine/.../service.py` | 分析/自动 ROI 透传 `device`；checkpoint 与日志记录；device 不进 `analysis_key`（换设备不重建代理） |
| `requirements-dml.txt` | 新增：`onnxruntime-directml` + `onnx` |
| `.github/workflows/release-packages.yml` | Windows 运行时安装 DML 依赖（装失败只告警） |
| `scripts/prepare_windows_runtime.ps1` | 打包时导出并携带动态 ONNX（失败告警，回退 CPU） |
| `scripts/check_runtime.py` | 新增 acceleration 报告（不参与 OK/FAILED 判定） |
| `tests/test_onnx_detector.py` | 新增 13 例：letterbox / preprocess / decode / NMS / 批大小策略 / 设备解析 / 回退 |
| `tests/test_analysis_adapter.py` | 新增 2 例：`--device` 透传到三个推理阶段与复核命令 |

回归：`pytest` **326 passed / 4 skipped**（改动前 311 / 4，新增 15 例，无既有失败）。

补充说明：`prepare_windows_runtime.ps1` 本身没有 BOM，Windows PowerShell 5.1 会按 ANSI 读取，因此新增的输出串只用 ASCII（中文注释不受影响），避免多字节字符把引号吃掉导致解析失败。
