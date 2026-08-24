# 贡献指南

感谢参与 Basketball Highlight Editor。当前项目处于源码预览阶段，欢迎提交问题、测试反馈和小范围修复。

## 开始前

1. 先阅读 `README.md`、`docs/DECISIONS_V1.md` 和对应模块文档；
2. 不要提交真实比赛视频、人物信息、标注数据、模型权重、构建产物或本机路径；
3. 涉及协议、数据库、分析流程或 UI 功能的改动，先在 Issue 中说明动机和验收方式；
4. 安全漏洞不要公开创建 Issue，参见 `SECURITY.md`。

## 本地检查

```bash
make setup-python
make check-open-source
make python-test

cd apps/desktop
flutter pub get
flutter analyze
flutter test
```

视频、FFmpeg 和模型是本地运行依赖。请在自己的机器上准备它们，不要把它们加入 PR。

## 提交规范

- 每个 PR 只解决一个清晰的问题；
- 说明改动范围、验证命令和已知限制；
- 保持现有 JSONL 协议和数据库兼容性；
- UI 改动请附上前后截图，并确认截图可以公开；
- 不要顺手修改无关文件或格式化整个目录。

## Pull Request 检查清单

- [ ] 已运行 `python3 scripts/check_open_source.py`；
- [ ] 已运行受影响的 Python/Flutter 测试；
- [ ] 没有提交视频、数据、模型、密钥或本机绝对路径；
- [ ] 文档已同步更新；
- [ ] 已说明许可证或第三方依赖影响。
