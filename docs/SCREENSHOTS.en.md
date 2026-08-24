# Product interface and workflow guide

[中文](SCREENSHOTS.md) · **English**

This guide follows the real desktop workflow and documents the main pages, buttons, and interactions. The screenshots are presented primarily in the **dark theme** so the GitHub documentation stays visually consistent. The available actions do not change with the theme.

## 1. Complete workflow

```text
Project home → New project → Import video → Set analysis range → Set detection regions
→ Choose Standard/Fast → Start analysis → Review candidates → Adjust and tag
→ Add a missed event (optional) → Merge or export clips separately
```

| Stage | Page | Main actions |
|---|---|---|
| 1 | Project home | Create/open a project, inspect recent projects and statistics |
| 2 | Import video | Choose a video, read metadata, replace a missing source |
| 3 | Analysis range | Preview, drag start/end points, use the full video, go back |
| 4 | Detection regions | Accept the automatic suggestion or adjust shot and hoop-net regions |
| 5 | Analysis confirmation | Choose Standard/Fast, inspect the estimate, go back, start analysis |
| 6 | Analysis progress | Follow the stage/progress, inspect timing, cancel the job |
| 7 | Review workbench | Play, switch, keep/exclude, filter, tag players, edit clip ranges |
| 8 | Export highlights | Filter by player, merge, export separately, return, open the output folder |

## 2. Page-by-page guide

### 1. Project home: start with a project

![Dark theme project home](../capture/screenshot-20260813-145724.png)

- Click **New project** to enter the import flow, or **Open project** to resume an existing project.
- **Current project** shows kept candidates, excluded candidates, and video duration.
- **Recent projects** can be opened directly or deleted when no longer needed.
- The workflow at the bottom shows the current path: import → ROI → analysis → review → export.

### 2. Import video: reference the local source

![Dark theme video import](../capture/screenshot-20260813-145741.png)

- Click **Choose video** to select MP4, MOV, M4V, AVI, or MKV footage.
- The source is referenced locally by default; it is not copied or uploaded.
- The app reads duration, resolution, frame rate, and codec information after loading.
- If the source was moved, use **Relink video** to choose it again instead of guessing a path.

### 3. Set the analysis range: analyze only what matters

![Dark theme analysis range](../capture/screenshot-20260813-145806.png)

- Play the video and locate the range to analyze.
- Drag the two timeline handles to set the **start** and **end** points.
- Click **Use full video** to restore the complete range.
- Go back to choose another video, or click **Next** to configure detection regions.
- A shorter range usually reduces analysis time but can miss events outside the range.

### 4. Set detection regions: automatic first, manual when needed

![Dark theme detection-region adjustment](../capture/screenshot-20260813-145835.png)

- The app first tries to suggest the hoop regions automatically.
- **Shot analysis region** covers the shooting trajectory, hoop, and landing area.
- **Hoop-net detection region** is used to observe net motion; avoid including too much floor, background, or players.
- Select a region tab, then drag its frame and handles in the video.
- Click **Reset hoop-net region** to restore the suggestion; manual setup is available when detection fails.

### 5. Confirm analysis: choose a mode and start

![Dark theme analysis confirmation](../capture/screenshot-20260813-145844.png)

- Confirm the video, analysis range, shot-analysis region, and hoop-net region.
- **Standard** favors completeness and refines candidates against the source video.
- **Fast** favors speed for a quick first pass and may miss events.
- The page shows an estimate; actual time depends on codec, disk, and device performance.
- Click **Back** to edit settings, or **Confirm configuration and start analysis**.
- The mode is locked after analysis begins. Cancel the job before switching modes.

### 6. Analysis progress: observable and cancellable

![Dark theme analysis progress](../capture/screenshot-20260813-145855.png)

- The top bar shows the current stage, progress, and elapsed time.
- Stages may include proxy generation, coarse scan, candidate generation, refinement, and preview preparation.
- Click **Cancel** in the upper-right corner to stop the current job.
- Candidates appear in the review workbench after completion; old candidates are not replaced until the new result succeeds.
- If the result is empty, check the model, detection region, range, and video format before reconfiguring or switching to Standard.

### 7. Review workbench: video first, candidates kept by default

![Dark theme review workbench: kept candidates](../capture/screenshot-20260813-150054.png)

- The video area is on the left and the time-ordered candidate list is on the right.
- Clicking a candidate switches the preview but **does not change its review state**.
- Click the green **Keep** button to keep a candidate, or the **Exclude** button to remove a false positive. Candidates are kept by default.
- Switch between **Candidate preview** and **Source video**, and toggle the annotation overlay.
- The player supports play/pause, seeking, skip controls, playback speed, replay, and looping.
- The evidence panel shows confidence, trajectory score, net motion, rebound judgment, and the system explanation.

![Dark theme review workbench: excluded candidates](../capture/screenshot-20260813-150109.png)

- Excluded candidates stay in the list so they can be restored or reviewed.
- Click **Keep** again to restore export eligibility; only excluded candidates are omitted from export.
- Filters include all, pending, confirmed, excluded, and low-confidence candidates.

### 8. Adjust a clip range: change only the export window

![Dark theme clip-range editor](../capture/screenshot-20260813-150120.png)

- Click **Adjust clip range** below a candidate to open the editor.
- Drag either end of the timeline or enter the start/end time directly.
- Click **Restore default** to return to the generated clip window.
- Click **Cancel** to discard changes or **Apply** to save them.
- This never modifies the source video; it only controls the time range exported for that candidate.

### 9. Tag players: make filtering and export easier

![Dark theme player tagging](../capture/screenshot-20260813-150302.png)

- Open the player selector on a candidate and assign a player tag.
- Choose an existing player or click **New player** to create one.
- Select multiple candidates to apply a player tag in batch.
- Player filters on the export page do not change keep/exclude decisions.

### 10. Add missed events, notes, and undo

These supporting actions are part of the workbench even though they are not split into separate screenshots:

- **Add a missed event:** switch to the source video, pause at the event, click **Add candidate from current source-video time**, set the range, and click **Add candidate**.
- **Notes:** open the candidate note editor to record the action, player, or reason for later review.
- **Undo review:** click the undo action or use `Cmd/Ctrl+Z` to undo the latest review decision.
- **Shortcuts:** `Space` play/pause, `R` replay, `L` loop, `A` toggle annotations, `↑/↓` switch candidates, `←/→` seek by 2 seconds, `C/Enter` keep, `X/Backspace` exclude.

### 11. Export highlights: merge or export separately

![Dark theme export screen](../capture/screenshot-20260813-150335.png)

- The page summarizes the currently kept candidates and total duration.
- Filter the export range by **All players** or a specific player.
- Click **Merge export** to create one event-ordered highlight reel.
- Click **Export separately** to create one video file per candidate.
- Excluded candidates are not exported; return to review if more changes are needed.
- After export, the app shows the output path, clip count, duration, elapsed time, file size, and codec, with an **Open folder** action.

## 3. Theme note

The **dark theme** is the recommended default and the primary theme used throughout this page. The light theme contains the same pages, copy, and actions; users can switch themes from the app settings or the top-right menu.

The light theme is shown only as a supplement:

![Light theme project home](../capture/screenshot-20260813-150603.png)

![Light theme empty review state](../capture/screenshot-20260813-150911.png)

## 4. Screenshot usage

These images document the interface only. The game footage and player images are demonstration material. Before publishing them, confirm rights from the camera operator, players, teams, venue, and other rights holders; do not commit real paths, unsanitized data, or unauthorized assets.
