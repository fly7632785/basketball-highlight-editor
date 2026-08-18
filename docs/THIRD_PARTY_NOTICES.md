# 第三方组件与参考项目说明

本文件区分“运行时依赖”和“研究参考”，不代表所有内容都可以随项目二进制再分发。

## 运行时依赖

| 组件 | 用途 | 来源 | 许可证核验状态 |
|---|---|---|---|
| Flutter / Dart | 桌面与移动端 UI | https://flutter.dev/ | 以对应 SDK 发布文件为准，发布包需保留其 notices |
| Python packages | Engine 与计算机视觉 | `requirements*.txt` | 发布前按锁定版本逐项核验 |
| Flutter packages | UI、视频和窗口能力 | `apps/*/pubspec.yaml` | 发布前按锁定版本逐项核验 |
| FFmpeg / FFprobe | 视频探测、代理和导出 | https://ffmpeg.org/ | 发布前确认编译配置和 LGPL/GPL 边界 |
| Inter font | 桌面 UI 字体 | https://github.com/rsms/inter | 当前公开分支不携带字体文件；若重新加入，须保留字体许可证和原始文件 |

## 研究参考仓库

研究阶段使用过的仓库、固定提交和许可证备注见：

- `docs/research/THIRD_PARTY_MANIFEST.md`
- `docs/research/LICENSE_NOTES.md`

研究参考仓库不属于本项目运行时依赖，公开源码不复制其代码、权重或数据。没有明确许可证的仓库不能作为可再分发代码使用。

## 发布前要求

1. 生成依赖清单并保留每个组件的许可证文本；
2. 单独核验模型权重、训练数据和编解码器；
3. 发布二进制时把对应 notices 放入安装包或发布附件；
4. 不把 MIT/Apache-2.0 代码许可证外推到模型权重或训练数据。
