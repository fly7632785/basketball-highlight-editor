# 测试数据说明

原始比赛视频不提交到 Git。

建议本地按以下结构放置：

```text
data/
├── videos/
├── labels/
└── artifacts/       # 自动生成的检测日志和调试结果，不提交 Git
```

标签至少记录每个真实进球的原始视频时间戳，用于计算 precision、recall 和 F1。
