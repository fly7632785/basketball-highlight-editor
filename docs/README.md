# 文档入口

**中文** · [English](README.en.md)

根目录 [`README.md`](../README.md) 是产品介绍和最短运行路径。本目录只保留“使用产品 → 理解产品 → 开发 → 架构 → 发布”所需的核心入口。

## 按任务查找

| 目标 | 从这里开始 |
|---|---|
| 第一次安装和运行桌面端 | [`GETTING_STARTED.md`](GETTING_STARTED.md) |
| 候选为空、模型、FFmpeg、插件警告 | [`FAQ.md`](FAQ.md) |
| 修改代码、补测试 | [`DEVELOPMENT.md`](DEVELOPMENT.md) |
| 打包 macOS/Windows | [`RELEASE.md`](RELEASE.md) |
| 理解桌面端架构 | [`architecture/ARCHITECTURE_V1.md`](architecture/ARCHITECTURE_V1.md) |
| 调试 Flutter ↔ Engine 协议 | [`architecture/ENGINE_PROTOCOL_V1.md`](architecture/ENGINE_PROTOCOL_V1.md) |
| 理解项目目录和缓存 | [`architecture/PROJECT_LAYOUT_V1.md`](architecture/PROJECT_LAYOUT_V1.md) |
| 理解移动端原生 Runtime | [`architecture/MOBILE_RUNTIME_V1.md`](architecture/MOBILE_RUNTIME_V1.md) |

## 用户文档

- [`GETTING_STARTED.md`](GETTING_STARTED.md)：Python、Flutter、FFmpeg、模型、运行时检查、首次使用和 Windows 实验路径。
- [`FAQ.md`](FAQ.md)：启动、候选、视频、导出、移动端和 macOS Swift Package Manager 警告。

## 开发与架构

- [`DEVELOPMENT.md`](DEVELOPMENT.md)：模块边界、测试、调试、协议/数据库变更和提交前检查。
- [`architecture/ARCHITECTURE_V1.md`](architecture/ARCHITECTURE_V1.md)：桌面 UI、Python Engine、算法、存储和任务生命周期。
- [`architecture/ENGINE_PROTOCOL_V1.md`](architecture/ENGINE_PROTOCOL_V1.md)：JSONL 请求、响应、事件、命令和错误码。
- [`architecture/PROJECT_LAYOUT_V1.md`](architecture/PROJECT_LAYOUT_V1.md)：源码树、用户项目树和缓存清理规则。
- [`architecture/MOBILE_RUNTIME_V1.md`](architecture/MOBILE_RUNTIME_V1.md)：Android/iOS 原生媒体与 Rust/ONNX 接入边界。
- [`../engine/python/README.md`](../engine/python/README.md)：独立 Engine 启动和当前命令概览。
- [`../apps/desktop/README.md`](../apps/desktop/README.md)：桌面 Flutter 模块。
- [`../apps/mobile/README.md`](../apps/mobile/README.md)：移动端开发和原生库准备。

## 产品文档

- [`DECISIONS_V1.md`](DECISIONS_V1.md)：当前产品、算法和工程决策；与旧记录冲突时优先看这里和运行时行为。
- [`REQUIREMENTS_V1.md`](REQUIREMENTS_V1.md)：V1 范围、已实现/部分实现/未完成状态和发布门槛。
- [`USER_FLOW_V1.md`](USER_FLOW_V1.md)：导入、分析、审核、导出和异常路径。

## 发布

- [`RELEASE.md`](RELEASE.md)：源码预览发布、桌面运行时、签名、公证和许可证检查。

## 文档约定

- “已实现”表示当前代码存在对应路径，不等于所有平台、视频和模型都已完成发布验收。
- “已验证”必须对应测试、运行日志或可复现实验；单个视频的耗时不能写成普遍保证。
- 当源码、文档和运行结果冲突时，优先核对 live runtime、协议和数据库状态，再更新文档。
- 不在文档中写入个人绝对路径、真实视频路径、密钥、未授权模型下载地址或未脱敏截图。
- 协议命令、数据库字段、分析参数或发布依赖发生变化时，同时更新本索引和对应中英文入口。

数据库 schema、模型授权和底层性能记录属于开发/发布材料，不放入产品主导航；需要时按相关文档中的说明查阅。
