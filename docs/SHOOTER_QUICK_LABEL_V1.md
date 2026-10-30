# 射手快标 / Shooter quick labeling

桌面端审核包含「进球审核」和「射手快标」，默认进入进球审核。

1. 分析视频后，进入「射手快标」。已有项目缺少画面时可用「补齐/刷新画面」。
2. 每张卡片默认显示中间帧，可切换前后帧或「显示全景蓝框」，必要时点「看视频」。
3. 点击球员姓名立即保存射手；每张卡片都可「添加球员」。数字 1–9 标记当前卡片。
4. 可标记「不确定」、清除或撤销上一次标注。射手与进球判断、片段取舍及备注独立。

画面直接复用现有低分辨率代理和篮球轨迹，不增加人物检测或额外球检测。
标准分析期间会显示只读预览；成功后正式候选与出手画面一起保存。失败或取消保留原数据。
出手区域和时间为近似估计，遮挡或轨迹缺失时应查看相邻帧、全景或视频。
已有球员标签及人工选帧会保留；图片位于项目目录中，应与源视频一起私密保存。

本版提供半自动标注，自动识别出手者的下一版正在开发中。

The desktop Review module opens Basket review by default. Select Shooter quick label
to label candidates from stills. Five portrait cards fit a desktop row; each defaults
to its middle frame and offers adjacent frames, full context and Watch clip.
Click a name to save, use Add player on any card, or press 1–9 for the selected card.
Uncertain, Clear and Undo operate independently from basket decisions and notes.
Existing projects can use Refresh stills; new analysis prepares them automatically
from its cached proxy and ball trajectories without additional detector inference.
Drafts are read-only. Failed or cancelled preparation preserves committed data.
Release regions are approximate; review ambiguous cases in video. Automatic shooter
recognition is being developed for a later version.
