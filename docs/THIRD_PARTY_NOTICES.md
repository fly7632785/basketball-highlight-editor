# 第三方组件与参考项目说明

本文件集中记录运行时依赖和研究参考。它**不是**对所有组件可以随本项目二进制再分发的承诺；正式发布时应根据锁定版本随发布物附上完整 notices。

## 运行时依赖

| 组件 | 用途 | 版本来源 | 发布前动作 |
|---|---|---|---|
| Flutter / Dart | 桌面和移动 UI | Flutter SDK、`apps/*/pubspec.lock` | 保留 SDK 和包 notices |
| `ultralytics` / PyTorch | 桌面检测与推理 | `requirements.txt` 和实际安装环境 | 锁定版本并核验许可证 |
| OpenCV / NumPy / pandas / psutil | 视频采样、数据处理和运行时监控 | `requirements.txt` | 锁定版本并核验许可证 |
| `ort` / ONNX Runtime | 移动端 Rust 推理路径 | `packages/bhe_runtime/Cargo.toml` 和 Android/iOS 原生库 | 核对 crate、动态库和 XCFramework 条款 |
| FFmpeg / FFprobe | 元数据、代理、预览和导出 | 系统或发布运行时 | 核对构建配置、LGPL/GPL 边界和 notices |
| `media_kit` / `video_player` | 桌面/移动视频播放 | `apps/*/pubspec.yaml` | 保留对应包和插件 notices |
| Inter 字体 | 桌面 UI 字体（如重新加入） | `apps/desktop/assets` | 核对字体文件和许可证 |

具体版本应以提交时的 lockfile、构建产物和发布清单为准，不要只复制这张表。

## 研究参考项目

以下项目曾用于理解 ROI、跳帧、轨迹、候选窗口、运动触发或剪辑流程。本项目不把它们作为运行时依赖，也不复制其代码、权重或训练数据：

| 项目 | 来源 | 本地研究记录 | 许可证结论 |
|---|---|---|---|
| `bball-highlights` | [GitHub](https://github.com/owengong/bball-highlights) | commit `e463b6acd8a9` | 当前研究 checkout 未确认可复制代码 |
| `AI_basketball_games_video_editor` | [GitHub](https://github.com/OwlTing/AI_basketball_games_video_editor) | commit `4390a2d734b9` | 代码和模型/数据需分别核验 |
| `Basketball-Shot-Detection` | [GitHub](https://github.com/josephattalla/Basketball-Shot-Detection) | commit `e320817d0f87` | 代码许可证与权重/数据需分别核验 |
| `OpenCV_Basketball_Shot_Tracker` | [GitHub](https://github.com/Muhammmadfakharulhasnain/OpenCV_Basketball_Shot_Tracker) | commit `486b5c0c098f` | 未确认完整许可证，不作为可复制代码来源 |
| `Sports-Highlight-Detector` | [GitHub](https://github.com/AkhilNam/Sports-Highlight-Detector) | commit `dcfd6dc435b4` | 代码许可证与依赖需分别核验 |
| `NBAction` | [GitHub](https://github.com/lin-simon/NBAction) | commit `14a2acd571de` | 代码和模型/数据需分别核验 |

这些提交标识是历史研究记录，不代表当前网络状态或上游项目仍保持不变。若要再次吸收实现，应重新阅读上游许可证并保留来源、版本和改动边界。

## 发布前要求

1. 根据实际 lockfile 生成依赖清单和许可证文本；
2. 单独核验模型权重、训练数据、视频素材和编解码器；
3. 二进制发布时把对应 notices 放入安装包或发布附件；
4. 不把 MIT/Apache-2.0 的代码许可证外推到模型权重或训练数据；
5. 不把研究参考项目误写成运行时依赖或项目共同作者。
