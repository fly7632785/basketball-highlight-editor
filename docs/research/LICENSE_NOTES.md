# 许可证与模型分发备注

## 当前仓库

- `bball-highlights`：当前浅克隆未发现许可证文件，暂不直接复制代码。
- `ai_basketball_games_video_editor`：仓库包含 Apache-2.0 文件，但模型权重、训练数据和第三方依赖仍需单独确认。
- `basketball-shot-detection`：仓库包含 MIT License；模型权重和训练数据仍需单独确认。
- `sports-highlight-detector`：仓库包含 MIT License。
- `nbaction`：仓库包含 Apache-2.0 相关许可证文件。
- `opencv-basketball-shot-tracker`：当前浅克隆未发现许可证文件，暂不直接复制代码。

## 模型与依赖

许可证判断必须拆成四层：

1. 应用代码许可证；
2. 模型权重许可证；
3. 训练数据许可证；
4. 推理框架和编解码器许可证。

不能因为代码仓库是 MIT 或 Apache-2.0，就默认模型和数据也可以用于闭源商业 App。

当前研究阶段只做个人本地验证，不作商业分发结论。

参考：

- [Ultralytics License](https://www.ultralytics.com/license)
- [ONNX Runtime Rust binding: ort](https://github.com/pykeio/ort)
