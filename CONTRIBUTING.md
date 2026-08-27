# 贡献指南

感谢参与 Basketball Highlight Editor。项目当前是源码预览版，欢迎提交问题、测试反馈、文档改进和聚焦明确的代码修复。

## 开始前

1. 先阅读根目录 [`README.md`](README.md) 或 [`README.en.md`](README.en.md)，再阅读 [`docs/README.md`](docs/README.md)；
2. 不要提交真实比赛视频、人物信息、标注、模型权重、原生二进制、构建产物或本机路径；
3. 涉及协议、数据库、分析流程、移动 Runtime 或 UI 的改动，请先说明动机、影响范围和验收方式；
4. 安全漏洞不要公开创建 Issue，参见 [`SECURITY.md`](SECURITY.md)。

## 本地检查

```bash
python3 scripts/check_open_source.py
.venv/bin/python -m pytest -q

cd apps/desktop
flutter pub get
flutter analyze
flutter test
```

移动端改动还应运行：

```bash
cd apps/mobile
flutter pub get
flutter analyze
flutter test
```

涉及候选生成、轨迹、穿框、篮网、反弹、评分、判决或自动导出门槛的改动，还必须阅读并遵守 [`docs/architecture/CROSS_PLATFORM_ANALYSIS_CONTRACT_V1.md`](docs/architecture/CROSS_PLATFORM_ANALYSIS_CONTRACT_V1.md)。这类改动必须同时检查 Python Engine 与 Rust Runtime；尚未完成跨端回放前，不得宣称结果一致。

视频、模型、FFmpeg、Android NDK、ONNX Runtime 和 iOS 工具链是本地运行依赖，请自行准备，不要把个人环境文件加入 PR。

## 提交规范

- 每个 PR 只解决一个清晰的问题；
- 说明改动范围、验证命令和已知限制；
- 保持现有 JSONL 协议、SQLite 和移动项目包兼容性，除非 PR 明确包含迁移；
- UI 改动请附已确认可以公开的前后截图；
- 不要顺手格式化整个目录或修改无关文件；
- 文档变更同时更新中英文入口或说明为什么不需要翻译。

## Pull Request 检查清单

- [ ] 已运行 `python3 scripts/check_open_source.py`；
- [ ] 已运行受影响的 Python/Flutter 测试；
- [ ] 没有视频、数据、模型、原生二进制、密钥或本机绝对路径；
- [ ] 文档命令与当前目录和脚本参数一致；
- [ ] 已说明许可证、第三方依赖或发布影响；
- [ ] 已在描述中记录未验证的部分。
- [ ] 算法改动已按跨端分析一致性契约检查 Python 与 Rust，并附跨端回放结果或明确缺口。
