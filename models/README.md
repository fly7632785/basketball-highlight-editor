# 模型目录

当前源码仓库已经包含默认桌面权重 `models/bball_model.pt` 和移动端 ONNX 产物。用户正常 clone 后不需要手动下载模型；模型缺失或需要替换时才使用自定义路径。

模型权重仍然是独立的发布对象。提交或分发前必须确认权重、训练数据、推理框架和导出格式的授权，不能因为源码采用 MIT 就默认模型也可以公开。

## 桌面端

Engine 默认查找：

```text
models/bball_model.pt
```

运行时会默认检查这个文件，也可以通过 `scripts/check_runtime.py --model /path/to/model.pt` 指定自定义路径。替换模型需要兼容当前检测脚本使用的类别和输入输出格式。

## 移动端

移动端可能需要 ONNX 模型和对应的 Rust/ONNX Runtime。模型转换入口见 [`../scripts/export_mobile_model.py`](../scripts/export_mobile_model.py)，Android/iOS 原生构建边界见 [`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md)。

## 公开发布前

请保留模型来源、版本、哈希、许可证和训练数据授权记录。当前仓库虽然携带模型，但在模型再分发权利完成核验前，不应把它描述为可自由商业分发的模型或单独发布下载地址。
