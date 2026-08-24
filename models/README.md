# 模型目录

模型权重是独立的发布对象。提交或分发前必须确认权重、训练数据、推理框架和导出格式的授权，不能因为源码采用 MIT 就默认模型也可以公开。

## 桌面端

Engine 默认查找：

```text
models/bball_model.pt
```

也可以通过 `scripts/check_runtime.py --model /path/to/model.pt` 指定自定义路径。模型需要兼容当前检测脚本使用的类别和输入输出格式。

## 移动端

移动端可能需要 ONNX 模型和对应的 Rust/ONNX Runtime。模型转换入口见 [`../scripts/export_mobile_model.py`](../scripts/export_mobile_model.py)，Android/iOS 原生构建边界见 [`../docs/architecture/MOBILE_RUNTIME_V1.md`](../docs/architecture/MOBILE_RUNTIME_V1.md)。

## 公开发布前

请保留模型来源、版本、哈希、许可证和训练数据授权记录。没有明确再分发许可时，只要求使用者自行准备模型，不要在 Release 附件或文档中提供未经核验的下载地址。
