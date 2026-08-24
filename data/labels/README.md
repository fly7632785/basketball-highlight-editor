# 标注格式示例

只提交不含真实视频、个人信息和本机路径的脱敏示例。时间单位为秒：

```csv
video,event_time,type,description
example.mp4,128.42,make,清晰进球
example.mp4,196.10,miss,擦筐或遮挡
```

建议类型：

- `make`：真实进球；
- `miss`：重点误报或漏检事件；
- `description`：遮挡、反弹、擦筐等说明。
