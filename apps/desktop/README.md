# Desktop App

桌面端 Flutter 应用。UI 通过 JSONL 协议调用仓库内的 Python Engine，不直接操作 SQLite、检测 JSON 或 FFmpeg。

## 技术栈

- Flutter / Dart；
- Riverpod 项目状态；
- go_router 页面路由；
- Material 3 和 `lib/theme/` 中的主题令牌；
- media_kit 视频播放；
- `engine/python` JSONL Engine。

## 模块

- `lib/app.dart`：应用壳和主题；
- `lib/core/`：协议客户端和会话状态；
- `lib/features/home/`：项目入口和最近项目；
- `lib/features/import_video/`：视频元数据、范围和 ROI；
- `lib/features/review/`：候选审核工作台；
- `lib/features/export/`：导出任务和统计。

## 本地开发

从仓库根目录：

```bash
cd apps/desktop
flutter pub get
flutter analyze
flutter test
flutter run -d macos
```

需要显式指定仓库运行时：

```bash
BHE_REPO_ROOT="$(pwd)/../.." \
BHE_PYTHON="$(pwd)/../../.venv/bin/python" \
flutter run -d macos
```

相关文档：

- [`../../docs/ARCHITECTURE.md`](../../docs/ARCHITECTURE.md)
- [`../../docs/DEVELOPMENT.md`](../../docs/DEVELOPMENT.md)
- [`lib/theme/app_theme.dart`](lib/theme/app_theme.dart)
