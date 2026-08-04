# 第三方项目直接运行测试

## 测试输入

```text
data/artifacts/third_party_tests/first_60s.mp4
时长：60.2 秒
来源：data/videos/飞书20260804-170744.mp4 前 60 秒
```

## 结果

| 项目 | 直接使用内容 | 结果 | 判断 |
|---|---|---|---|
| `basketball-shot-detection` | `Shot_Detector` + `bball_model.pt`，`step=2` | 运行约 55 秒，`makes=0`、`attempts=0` | 代码默认全画面检测；当前视频中篮筐/篮球太小，直接运行没有形成轨迹，不适合作为最终入口 |
| `bball-highlights` | `detect_makes_yolo.py` + `yolo11m.pt`，15 FPS，手工校准 ROI | 检测到 96/900 帧有球，未输出 make | 通用 `sports ball` 模型和原项目几何阈值需要针对本视频重新校准 |
| 当前适配基线 | `bball_model.pt` + ROI 放大 4 倍 + 自己的几何候选逻辑 | 全视频 48.47 秒，得到 11 个候选 | 当前视频的最佳起点，但候选仍需二次精判 |

## 结论

**可以直接使用开源项目的模型和算法模块进行测试，但不能直接把它们的完整命令行程序当成产品入口。**原因是参考项目的默认假设与当前视频不完全一致：

- `basketball-shot-detection` 默认全画面检测，没有利用当前固定机位的篮筐 ROI；
- `bball-highlights` 使用 COCO 通用 `sports ball`，当前视频的篮球和篮筐像素尺寸偏小；
- 两个项目的几何参数都针对各自视频调过，不能原样套用；
- 当前视频中篮筐检测框约 19×23 像素，需要 ROI 放大和原视频精扫。

## 当前采用的组合

```text
使用 basketball-shot-detection 的 bball_model.pt
  ↓
借鉴 bball-highlights 的 ROI、缓存、粗扫/精扫和验证流程
  ↓
保留其几何穿越思想，但重新校准篮筐线、速度和反弹规则
```

OwlTing 的 YOLOv4 权重暂不作为第一轮入口：它的运行栈更旧，当前测试尚未证明它能优于 `bball_model.pt`。
