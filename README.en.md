# BHE: Basketball Highlight Editor

BHE is a basketball highlight tool. Give it a fixed-camera game video; it finds likely baskets for you to review and export.

Stop cutting highlights until midnight. Finding each basket in an hour or two of footage means scrubbing through the game and cutting each moment by hand.

BHE analyzes on your own computer or Android phone and lines up likely baskets so you can remove false positives. It is free, runs locally, and does not upload your video.

[![Latest tag](https://img.shields.io/github/v/tag/fly7632785/basketball-highlight-editor?include_prereleases&style=flat-square&label=latest%20tag)](https://github.com/fly7632785/basketball-highlight-editor/tags)
[![License](https://img.shields.io/github/license/fly7632785/basketball-highlight-editor?style=flat-square)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows%20%7C%20Android%20%7C%20iOS-4c6ef5?style=flat-square)
![Local first](https://img.shields.io/badge/operation-local--first-2ea44f?style=flat-square)
[![Python Tests](https://img.shields.io/github/actions/workflow/status/fly7632785/basketball-highlight-editor/python-tests.yml?branch=main&style=flat-square&label=Python%20tests)](https://github.com/fly7632785/basketball-highlight-editor/actions/workflows/python-tests.yml)
[![Flutter Checks](https://img.shields.io/github/actions/workflow/status/fly7632785/basketball-highlight-editor/flutter-check.yml?branch=main&style=flat-square&label=Flutter%20checks)](https://github.com/fly7632785/basketball-highlight-editor/actions/workflows/flutter-check.yml)
![Free](https://img.shields.io/badge/cost-free-f97316?style=flat-square)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg?style=flat-square)](CONTRIBUTING.md)
[![Linux DO](https://img.shields.io/badge/Linux%20DO-community-00a67d?style=flat-square)](https://linux.do/)

[简体中文](README.md) · **English**

[Website](https://bhe.jafir.top/en/) · [Download](#download) · [Quick start](#quick-start) · [Features](#highlights-professional-and-fast) · [FAQ](#faq) · [Documentation](#documentation)

<img src="docs/screenshots/readme-0.1.13/review.webp" alt="Review workbench, shown in Chinese" width="100%">

[Watch the demo](https://github.com/user-attachments/assets/43bfed76-bbc6-42c2-bbaa-ea2bf0604292) · [Alternative video](https://shengshengniannian.oss-cn-beijing.aliyuncs.com/shengshengniannian/basketball-highlight-editor/recording-demo.mp4)

<a id="features"></a>

## Highlights: professional and fast

- **Shortcuts and speed**: play at 1.5× / 2×, use ↑↓ to change clips, ←→ to seek, X to exclude, 1–9 (Q onward after the ninth) to tag players, and Cmd/Ctrl+Z to undo.
- **Tag groups**: save player and tag groups and import them into the next project.
- **Add missed clips and adjust timing**: add moments from the source video; the default is 3 seconds before and 1 second after, adjustable globally or per clip.
- **Export by tag**: choose players or tags, merge everything, export individual clips, or merge one video per tag.

Use the suggested hoop area and adjust it when needed. Desktop export offers optional slow motion; game statistics are estimates and may be inaccurate.

## Download

Current release: [v0.1.13](https://github.com/fly7632785/basketball-highlight-editor/releases/tag/v0.1.13). Downloads are also available from the [website](https://bhe.jafir.top/en/#download) and [GitHub Releases](https://github.com/fly7632785/basketball-highlight-editor/releases).

| System | v0.1.13 package | Notes |
|---|---|---|
| macOS | [Apple silicon](https://github.com/fly7632785/basketball-highlight-editor/releases/download/v0.1.13/BHE-macos-arm64-v0.1.13-adhoc.dmg) · [Intel](https://github.com/fly7632785/basketball-highlight-editor/releases/download/v0.1.13/BHE-macos-x86_64-v0.1.13-adhoc.dmg) | Intel Macs require macOS 13 or later. On first launch, right-click and select Open. |
| Windows 10 / 11 | [x64 .zip](https://github.com/fly7632785/basketball-highlight-editor/releases/download/v0.1.13/BHE-windows-x64-v0.1.13.zip) | Extract the archive; see [setup notes](docs/GETTING_STARTED.en.md). |
| Android | [arm64-v8a .apk](https://github.com/fly7632785/basketball-highlight-editor/releases/download/v0.1.13/BHE-android-arm64-v8a-v0.1.13-debug-signed.apk) | Sideloaded test package; allow installation from unknown sources. |

On a Snapdragon 8 Elite Gen 5 phone, a 10-minute video took about 4.5 minutes to analyze; other devices differ. See the v0.1.9 notes below. iPhone can play, review and export, but cannot analyze yet.

<a id="quick-start-desktop"></a>

## Quick start

1. Download and open BHE.
2. Create a project and select your game video. Desktop also supports several videos of one game.
3. Check the analysis range and hoop area, choose Standard or Fast, and start analysis.
4. Review the candidates, remove false positives, add missed clips, and tag players or scenes.
5. Choose an export range and output mode.

## Screenshots

The screenshots show the Chinese-language interface.

Desktop:

<p align="center"><img src="docs/screenshots/readme-0.1.13/duration.webp" alt="Bulk clip duration settings in Chinese" width="49%"> <img src="docs/screenshots/readme-0.1.13/export.webp" alt="Export range and output modes in Chinese; export history is obscured" width="49%"></p>

Android:

<p align="center"><img src="docs/screenshots/readme-0.1.13/mobile-analysis.webp" alt="Android analysis settings in Chinese" width="24%"> <img src="docs/screenshots/readme-0.1.13/mobile-export.webp" alt="Android export modes in Chinese" width="24%"></p>

## Suitable footage

Use a steady fixed camera with a clear view of one hoop. A position around 45° near the top of the key or near the court logo can work well. Full-court footage with two hoops, frequent camera movement, or prolonged obstruction is outside the ideal use case.

## FAQ

- **Does it need internet?** Analysis, review and export run locally; downloads and online documentation need a connection.
- **Is it free?** The source is MIT licensed, with no per-minute or per-export charge; models and footage have their own licenses.
- **What if detection is wrong?** Exclude false positives, adjust timing, and add missed clips manually.
- **What about iPhone and full-court footage?** iPhone cannot analyze yet; detection currently handles one hoop at a time.

## Recent updates

See [CHANGELOG](CHANGELOG.md) for all changes. Windows one-click updates start with `v0.1.12-windows.1` and require one initial manual replacement.

| Version | Date | Highlights |
|---|---|---|
| v0.1.13 | 2026-10-28 | Android adds a project list (open, rename, delete, close a project), three output modes on the export page (including one merged video per tag), game stats, export history and a reminder about untagged clips before exporting, and moves undo into the menu; Android can select a player group and check who is playing before analysis, edit groups, undo up to 20 review actions, rename or delete player tags, and rename projects; adds feedback, diagnostics, task recovery guidance and clearer errors; analysis and export cannot run at the same time; merged exports combine overlapping clips and show the reduction in clip count, while separate exports now run one by one and may take longer; fixes export failures for some videos, video recovery, project package path safety and portrait export orientation, preserving existing reviews if source validation fails; desktop merged exports combine overlapping clips from the same video when no goal effect is selected, and review shows Edited and Overlap labels; Windows checks the analysis engine earlier; diagnostics are improved and future platform-specific patches are supported |
| v0.1.12-windows.1 | 2026-10-26 | Windows hotfix: one-click update installation with rollback protection, requiring a first manual replacement; skip unrecognized audio tracks during export; includes editable player groups and roster selection when importing |
| v0.1.12-macos.2 | 2026-10-26 | macOS export hotfix: skip unrecognized audio tracks to fix FFmpeg exit code 234; preserve normal audio in separate, merged and manual clip exports |
| v0.1.12 | 2026-10-26 | Export can add a goal effect: slow motion into the shot or a slow-motion close-up replay; the export page shows game stats (estimated hit rate, goals per player, goals over time) and can merge one video per tag; clips now default to 3 s before and 1 s after the goal; Windows can analyze on the GPU and Mac uses CoreML, so analysis is faster; fixed scrambled portrait videos and upside-down iPhone videos on Windows, exports failing without a file extension, and some Windows PCs that could not analyze or create projects |
| v0.1.11 | 2026-10-23 | Desktop and Android check for updates in the app and verify the package before installing; Feedback copies diagnostics in one step and errors can be reported directly; engine logs record the environment, video specs, stage timings and failure reasons; Android packages are now signed with a fixed certificate so later versions install over the old one; fixed video playback in multi-part project review |
| v0.1.10 | 2026-10-23 | One desktop project can hold several videos of the same game, ordered by recording time, analyzed in a queue, and reviewed and exported together; separately exported clips include the player name in the file name; save player lists as groups and import them into other projects; desktop writes engine logs to a fixed folder you can open from About; fixed analysis stuck at 1% on Chinese-locale Windows and export failures on iPhone spatial-audio videos |
| v0.1.9 | 2026-10-22 | Android analyzes on the NPU on Snapdragon 8 Elite Gen 5 phones (about 4.5 minutes for a 10-minute video); Android adds the frame-by-frame rim check and coarse fallback candidates, matching desktop results; a camera that drifts mid-game no longer loses goals in the second half; mobile review adds rim-check and player filters, the timeline range editor, and project covers |
| v0.1.8 | 2026-10-21 | The rim check only excludes on evidence it actually saw, cutting missed goals on three reviewed videos from 47 to 0; review list can filter by rim-check result; Windows decodes proxies and encodes exports on the GPU; fixed black borders on non-16:9 videos on Windows and unreadable text in the light theme |
| v0.1.7 | 2026-10-20 | Standard analysis adds a frame-by-frame rim check that auto-excludes missed shots; drag a video onto the home screen to create a project, with project covers; redesigned clip range editing and number-key player tags; fixed a batch of review and export freezes and state bugs |
| v0.1.4 – v0.1.6 | 2026-10-17 | Review video fills the panel; fixed proxy generation and export in the Windows package, followed by several Windows hotfixes from 10-18 to 10-20 |
| v0.1.1 – v0.1.3 | 2026-09-16 – 09-23 | Full Chinese and English UI on desktop and mobile; fixed Android native library loading and the ONNX Runtime version |
| v0.1.0 | 2026-09-14 | First preview release: automated macOS, Windows, and Android test builds, downloadable from the website; mobile ported the desktop analysis algorithm |

## Support and community

If this helps you, buy the author a coffee.

<p align="center"><img src="docs/images/coffee-wechat.png" alt="WeChat Pay QR code" width="180"></p>

### BHE user group

Scan to add me on WeChat and note "BHE group".

<p align="center"><img src="website/assets/wechat-qr.png" alt="Author's WeChat QR code" width="150"></p>

## Documentation

- [Getting started](docs/GETTING_STARTED.en.md) · [Development](docs/DEVELOPMENT.en.md) · [Architecture](docs/architecture/ARCHITECTURE_V1.md) · [Mobile capabilities](docs/MOBILE_PC_FEATURE_MATRIX.md)
- [Report an issue](https://github.com/fly7632785/basketball-highlight-editor/issues) · [Website](https://bhe.jafir.top/en/)
- Privacy and licensing: processing is local; source, models, footage and third-party dependencies have separate terms. See [license notes](docs/MODEL_AND_DATA_LICENSES.md) and the [third-party manifest](docs/THIRD_PARTY_NOTICES.md).
- Thanks to the [Linux.do](https://linux.do/) community and all contributors.

[Website (Chinese)](https://bhe.jafir.top) · [Runtime requirements](requirements.txt) · [Development requirements](requirements-dev.txt)

More existing references: [`docs/USER_FLOW_V1.md`](docs/USER_FLOW_V1.md) · [`docs/README.en.md`](docs/README.en.md) · [`apps/mobile/README.md`](apps/mobile/README.md) · [`docs/MOBILE_PC_FEATURE_MATRIX.md`](docs/MOBILE_PC_FEATURE_MATRIX.md) · [`CHANGELOG.md`](CHANGELOG.md) · [Desktop architecture](docs/architecture/ARCHITECTURE_V1.md) · [Engine protocol](docs/architecture/ENGINE_PROTOCOL_V1.md) · [Mobile runtime](docs/architecture/MOBILE_RUNTIME_V1.md) · [Project layout and lifecycle](docs/architecture/PROJECT_LAYOUT_V1.md) · [`docs/GETTING_STARTED.en.md`](docs/GETTING_STARTED.en.md) · [`docs/MODEL_AND_DATA_LICENSES.md`](docs/MODEL_AND_DATA_LICENSES.md) · [`models/README.md`](models/README.md) · [`docs/FAQ.en.md`](docs/FAQ.en.md) · [`docs/research/ANALYSIS_MODES_V1.md`](docs/research/ANALYSIS_MODES_V1.md) · [`docs/benchmarks/ANALYSIS_MODE_BENCHMARK_20260812.md`](docs/benchmarks/ANALYSIS_MODE_BENCHMARK_20260812.md) · [`docs/architecture/ENGINE_PROTOCOL_V1.md`](docs/architecture/ENGINE_PROTOCOL_V1.md) · [`docs/architecture/MOBILE_RUNTIME_V1.md`](docs/architecture/MOBILE_RUNTIME_V1.md) · [`docs/RELEASE.en.md`](docs/RELEASE.en.md) · [`docs/DEVELOPMENT.en.md`](docs/DEVELOPMENT.en.md) · [`CONTRIBUTING.md`](CONTRIBUTING.md) · [`docs/architecture/`](docs/architecture/) · [`docs/DECISIONS_V1.md`](docs/DECISIONS_V1.md) · [`docs/REQUIREMENTS_V1.md`](docs/REQUIREMENTS_V1.md) · [`docs/OPEN_SOURCE_AUDIT.md`](docs/OPEN_SOURCE_AUDIT.md) · [`docs/THIRD_PARTY_NOTICES.md`](docs/THIRD_PARTY_NOTICES.md) · [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md) · [`SECURITY.md`](SECURITY.md) · [`LICENSE`](LICENSE) · [HoopCut](https://github.com/RuiYang0122/HoopCut) · [basketball-highlights](https://github.com/reborncd/basketball-highlights) · [ShotMarker](https://github.com/zhangrunhao/ShotMarker) · [basketball_clipper](https://github.com/snowroll/basketball_clipper) · [ball-yolo](https://github.com/griftt/ball-yolo) · [ClarkWang1214/basketball-highlights](https://github.com/ClarkWang1214/basketball-highlights) · [ai-sports-cut-agent](https://github.com/bond0060/ai-sports-cut-agent) · [MIT License](LICENSE) · [`NOTICE`](NOTICE)
