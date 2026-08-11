# Courtside 桌面端 UI 重构规范（Apple 风格）

## 目标

- 面向 macOS / Windows 的视频审核桌面工具；审核视频与候选操作优先于装饰性面板。
- 使用 macOS 的信息层级：侧栏、轻量工具栏、分组内容、原生感的悬停/焦点/快捷键反馈。
- 默认深色，但保留浅色与系统主题；不改变项目、分析、审核、导出等业务行为。

## 图标决策

| 方案 | 结论 | 原因 |
| --- | --- | --- |
| `sf_symbols` | 不采用 | Pub 描述与仓库都表明它仅使用 iOS 原生 SF Symbols，无法覆盖 Windows 桌面端。|
| `phosphor_flutter` | 不采用 | 跨平台且图标足够多，但会新增图标字体包，视觉也不是 Apple 系统符号。|
| `cupertino_icons` / `CupertinoIcons` | 采用 | 工程已具备该依赖；它是 Flutter 官方维护的 Apple 风格图标资产，跨桌面构建无需新增运行时依赖。|

来源：
- Apple SF Symbols: <https://developer.apple.com/sf-symbols/>
- Flutter Cupertino Icons: <https://pub.dev/packages/cupertino_icons>
- sf_symbols: <https://pub.dev/packages/sf_symbols>
- phosphor_flutter: <https://pub.dev/packages/phosphor_flutter>

## 视觉规则

- **色彩**：系统黑/系统灰为底；唯一的交互主色是系统蓝，篮球橙只保留给内容和体育语义。
- **排版**：macOS 使用系统 SF Pro；其他桌面回退 Inter。标题克制，正文不滥用粗体。
- **层级**：不再用每个模块都画边框。页面用留白和分组组织；仅浮层、视频控制条、可点选项目显示表面与边界。
- **图标**：统一采用 `CupertinoIcons` 的 18/20px 线性符号；状态色不只靠颜色，还要配文字或符号。
- **交互**：悬停、按下、键盘焦点均使用 150–220ms 的透明度/颜色变化，不做改变布局的缩放。

## 页面实施范围

1. 应用壳：缩窄侧栏、系统化工具栏、原生分段导航与图标。
2. 公共组件：按钮、分组表面、提示、状态、空状态、进度样式统一。
3. 项目：去掉营销式 Hero 与三列卡片，改为“项目 + 最近项目”列表式工作台。
4. 导入：信息按“视频 / 范围 / 校准 / 分析”分段，减少大卡片嵌套。
5. 审核：保持视频最大化，候选列表、证据和播放器控件使用低噪声的紧凑分组。
6. 导出：改为摘要分组和明确的主要/次要导出操作。

## 验收

- 所有主导航、工具栏、通知与按钮不再依赖 Lucide 图标。
- 深浅主题对比度与焦点态可见；窗口 1180px 宽度不溢出。
- 现有 Flutter 测试、Python 测试、`flutter analyze` 与 macOS Debug 构建通过。
