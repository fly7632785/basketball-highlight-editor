# V1 项目目录与生命周期

## 1. 仓库目录

```text
basketball-highlight-editor/
├── apps/
│   └── desktop/                    Flutter macOS 工程（已创建，Windows 后续启用）
├── engine/
│   └── python/
│       ├── basketball_engine/      Engine 进程
│       └── README.md
├── src/                            当前算法库（如存在）
├── scripts/                        当前算法脚本
├── data/                           本地研发数据，不进入正式项目目录
└── docs/
    └── architecture/
```

## 2. 用户项目目录

```text
<project-root>/
├── project.db
├── artifacts/
│   ├── proxies/
│   ├── detections/
│   ├── review_clips/
│   └── exports/
├── logs/
├── telemetry_outbox/                默认为空，授权后才使用
└── README.txt
```

原始视频默认保留在原位置，数据库保存：

- 绝对路径；
- 文件大小；
- 修改时间；
- SHA-256 可选校验值；
- 视频时长、分辨率、帧率、编码。

如果原始文件移动，UI 显示“重新定位视频”，不自动猜测新路径。

## 3. 缓存清理规则

可删除：

- 代理视频；
- 检测缓存；
- 已导出的临时片段；
- 失败任务的临时目录。

不可自动删除：

- 原始视频；
- SQLite 数据库；
- 用户审核记录；
- 用户明确保留的导出文件。
