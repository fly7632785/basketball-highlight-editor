# 第三方代码复用矩阵

| 参考项目 | 可复用内容 | 直接复用 | 改造后复用 | 仅参考 | 许可证状态 |
|---|---|---:|---:|---:|---|
| [`bball-highlights`](../../third_party/bball-highlights) | 篮筐校准、篮筐 ROI、YOLO 篮球检测、上方到下方的篮筐平面判断、缓存、precision/recall/F1 验证、FFmpeg 导出 |  | ✓ |  | 未发现仓库许可证文件，不能直接纳入产品代码 |
| [`ai_basketball_games_video_editor`](../../third_party/ai_basketball_games_video_editor) | YOLO 篮球/篮筐/球员检测、射门帧判断、日志、中间结果和集锦导出流程 |  | ✓ |  | Apache-2.0；依赖和推理栈较旧 |
| [`basketball-shot-detection`](../../third_party/basketball-shot-detection) | 目标关联、篮球进入篮筐上方区域、下方轨迹、篮筐几何判断、跳帧参数 |  | ✓ |  | MIT |
| [`opencv-basketball-shot-tracker`](../../third_party/opencv-basketball-shot-tracker) | HSV 颜色筛选、轨迹拟合、传统视觉基线 |  |  | ✓ | 未发现许可证文件 |
| [`sports-highlight-detector`](../../third_party/sports-highlight-detector) | 前置/后置时间、冷却时间、片段合并、运动平滑 |  | ✓ |  | MIT |
| [`nbaction`](../../third_party/nbaction) | 篮球/篮筐/球员检测、动作识别、稳定化和调试可视化 |  |  | ✓ | Apache-2.0；范围超出当前 MVP |

## 当前结论

最值得作为算法基线的是 `bball-highlights`，最值得作为工程流程参考的是 `ai_basketball_games_video_editor`，最值得借鉴几何判断的是 `basketball-shot-detection`。

没有任何一个仓库可以直接作为最终产品框架。建议提取算法思想和小模块，重新建立自己的数据接口、缓存格式、审核状态和导出流程。
