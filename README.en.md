# 🏀 Basketball Highlight Editor

> Turn a full basketball game into highlights you can actually share.

A **local AI basketball video editing tool** that finds suspected scoring moments, lets you review them quickly, and exports a highlight reel when you are ready.

[中文](README.md) · **[Getting started](docs/GETTING_STARTED.en.md)** · [FAQ](docs/FAQ.en.md)

## Why try it?

| The problem | How Basketball Highlight Editor helps |
|---|---|
| Rewatching a whole game takes too long | AI scans the video and proposes suspected scoring moments |
| Fully automatic editing is hard to trust | Review, keep, exclude, adjust, or add every candidate yourself |
| You do not want to upload game footage | Analysis, preview, review, and export run locally by default |
| You want speed without losing control | Choose between Fast and Standard analysis |

## From game footage to highlights

```text
Import video  →  Analyze with AI  →  Review candidates  →  Export highlights
```

1. **Import** a game video and inspect its metadata.
2. **Analyze** the hoop area and suspected scoring events.
3. **Review** candidates in the video workbench, adjust ranges, or add missing moments.
4. **Export** separate clips or one merged highlight reel in event-time order.

## What you can do

- Automatically suggest a hoop region, with manual drawing and adjustment when needed;
- Use **Standard** mode for a more complete analysis or **Fast** mode for a quicker first pass;
- Play candidates on the source video, keep or exclude them, adjust ranges, and add notes;
- Keep candidates by default instead of confirming every item one by one;
- Export clips separately or merge them into one timeline-ordered reel;
- See analysis progress, stage timing, recovery information, and export history.

## Who is it for?

- Players and coaches creating highlights from school, amateur, or training games;
- Anyone who wants to review a game without scrubbing through every minute manually;
- Creators and developers who want local processing and human control over the final edit.

The current pipeline is optimized for **fixed-camera, single-hoop, single-game videos**. AI narrows the search; you make the final call.

## Quick start (macOS)

The complete source repository includes the default detector, so a normal clone does not require a separate model download.

### 1. Prepare the environment

You need Python 3.11, Flutter stable, and FFmpeg. On macOS, install FFmpeg with Homebrew:

```bash
brew install ffmpeg
```

### 2. Install project dependencies

```bash
# Copy the repository URL from GitHub's Code menu
git clone <repository-url>
cd basketball-highlight-editor

python3.11 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -r requirements-dev.txt
```

### 3. Check and run

```bash
.venv/bin/python scripts/check_runtime.py \
  --root . \
  --python .venv/bin/python

cd apps/desktop
flutter pub get
flutter run -d macos
```

Then follow: create a project → choose a video → analyze → review → export. Windows, mobile, and troubleshooting details are in [`docs/GETTING_STARTED.en.md`](docs/GETTING_STARTED.en.md).

## Two analysis modes

| Mode | Best for | What it does |
|---|---|---|
| **Standard** | Important games and higher completeness | Quality first, including source-video refinement |
| **Fast** | A quick first pass and rapid browsing | Speed first, with a possibility of missed events |

Both modes use the same review, adjustment, and export workflow. Fast mode does not make decisions for you; it helps you reach the first reviewable result sooner.

## Core technology (for developers)

- **Flutter** for desktop and mobile UI;
- **Python + OpenCV + YOLO** for video sampling, basketball/hoop detection, and candidate generation;
- **SQLite** for project, job, candidate, and review state;
- **FFmpeg / FFprobe** for metadata, previews, and export;
- **Rust + ONNX Runtime** for the mobile native-inference path.

For implementation details, start with [`docs/README.en.md`](docs/README.en.md), then see [`docs/DEVELOPMENT.en.md`](docs/DEVELOPMENT.en.md) and [`docs/architecture/`](docs/architecture/).

## Current status

The macOS desktop app is the most complete and recommended path today. Windows and mobile projects have development entry points but remain experimental and are still being refined.

## Documentation

- **Getting started**: [`docs/GETTING_STARTED.en.md`](docs/GETTING_STARTED.en.md) · [`docs/FAQ.en.md`](docs/FAQ.en.md)
- **Product docs**: [`docs/USER_FLOW_V1.md`](docs/USER_FLOW_V1.md) · [`docs/REQUIREMENTS_V1.md`](docs/REQUIREMENTS_V1.md) · [`docs/DECISIONS_V1.md`](docs/DECISIONS_V1.md)
- **Development**: [`docs/DEVELOPMENT.en.md`](docs/DEVELOPMENT.en.md)
- **Architecture**: [`docs/README.en.md`](docs/README.en.md) · [`docs/architecture/`](docs/architecture/)
- **Release**: [`docs/RELEASE.en.md`](docs/RELEASE.en.md)

## Open-source acknowledgments

The model, detection workflow, and product ideas were informed by [HoopCut](https://github.com/RuiYang0122/HoopCut), [basketball-highlights](https://github.com/reborncd/basketball-highlights), [ShotMarker](https://github.com/zhangrunhao/ShotMarker), [basketball_clipper](https://github.com/snowroll/basketball_clipper), [ball-yolo](https://github.com/griftt/ball-yolo), [basketball-highlights](https://github.com/ClarkWang1214/basketball-highlights), and [ai-sports-cut-agent](https://github.com/bond0060/ai-sports-cut-agent). Thanks to all of the authors for sharing their work.

## Privacy and license

Videos are referenced locally and are not uploaded to a cloud service by default. The source code is released under the [MIT License](LICENSE); models, training data, video assets, and third-party dependencies remain subject to their own terms.

If this project helps you, try it, share feedback, or leave a Star on GitHub ⭐
