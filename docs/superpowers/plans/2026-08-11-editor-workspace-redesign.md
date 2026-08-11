# Courtside Editor Workspace Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild all four desktop pages into a coherent professional video-editor workspace while preserving every existing project, analysis, review, and export behavior.

**Architecture:** Keep Riverpod state, route paths, media_kit playback, and Engine requests unchanged. Replace only layout composition and visual components: the shell exposes a compact contextual workspace; import and review use canvas-first split layouts; project and export use compact media rows and inspectors rather than dashboard cards.

**Tech Stack:** Flutter 3.44 / Material 3, Cupertino Icons, Riverpod, go_router, media_kit, flutter_test.

---

### Task 1: Restore a clean visual baseline and establish workspace primitives

**Files:**
- Modify: `apps/desktop/lib/theme/app_colors.dart`
- Modify: `apps/desktop/lib/theme/tokens.dart`
- Modify: `apps/desktop/lib/theme/app_theme.dart`
- Create: `apps/desktop/lib/components/cs_workspace.dart`
- Modify: `apps/desktop/lib/components/cs_scaffold.dart`
- Modify: `apps/desktop/lib/components/cs_sidebar_shell.dart`
- Test: `apps/desktop/test/theme/app_colors_test.dart`
- Test: `apps/desktop/test/theme/app_theme_test.dart`

- [ ] **Step 1: Replace the previous pure-black palette with the editor workspace palette.**

```dart
const darkAppColors = AppColors(
  background: Color(0xFF0F1115),
  surface: Color(0xFF181B21),
  surface2: Color(0xFF20242C),
  surface3: Color(0xFF2B303A),
  textPrimary: Color(0xFFF2F4F7),
  textSecondary: Color(0xFFB4BAC4),
  textTertiary: Color(0xFF7E8796),
  border: Color(0xFF2A2F38),
  borderStrong: Color(0xFF3A4250),
  indigo: Color(0xFF4D9DFF),
  orange: Color(0xFFFFA62B),
  goal: Color(0xFF48C774),
  pending: Color(0xFFF4C95D),
  excluded: Color(0xFF8D96A5),
  success: Color(0xFF48C774),
  error: Color(0xFFFF6B6B),
  warning: Color(0xFFF4C95D),
);
```

- [ ] **Step 2: Add a `CsWorkspace` shell primitive that supplies a compact page toolbar and a canvas-safe content slot.**

```dart
class CsWorkspace extends StatelessWidget {
  const CsWorkspace({
    required this.title,
    required this.child,
    this.subtitle,
    this.actions = const [],
    super.key,
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      _WorkspaceToolbar(title: title, subtitle: subtitle, actions: actions),
      Expanded(child: child),
    ],
  );
}
```

- [ ] **Step 3: Make the global shell only render navigation and global task state; page titles move into `CsWorkspace`.**

```dart
// CsScaffold wide layout
return Scaffold(
  body: Row(
    children: [
      CsSidebarShell(...),
      Expanded(child: shell),
    ],
  ),
);
```

- [ ] **Step 4: Verify global theme and shell tests.**

Run:

```bash
cd apps/desktop
HOME="$TMPDIR/courtside-flutter-home" PATH="$PWD/../../.tooling/flutter/bin:$PATH" flutter test test/theme/app_colors_test.dart test/theme/app_theme_test.dart test/router/app_router_test.dart
```

Expected: all tests pass and no 8px overflow occurs when the sidebar is collapsed.

### Task 2: Rebuild the project page as a media library

**Files:**
- Modify: `apps/desktop/lib/features/home/home_screen.dart`
- Create: `apps/desktop/lib/components/media_project_row.dart`
- Test: `apps/desktop/test/home_screen_test.dart`

- [ ] **Step 1: Replace Hero text, workflow steps, and generic metrics cards with a `CsWorkspace` header and media library list.**

```dart
return CsWorkspace(
  title: '项目库',
  subtitle: '本机项目',
  actions: [newProjectButton, openProjectButton],
  child: _ProjectLibrary(
    projects: state.recentProjects,
    onOpen: openRecentProject,
    onDelete: deleteRecentProject,
  ),
);
```

- [ ] **Step 2: Render each recent project as `MediaProjectRow`, with source video, duration, candidate count, included count, a thumbnail placeholder, and an overflow delete menu.**

```dart
class MediaProjectRow extends StatelessWidget {
  const MediaProjectRow({
    required this.name,
    required this.sourceName,
    required this.duration,
    required this.candidates,
    required this.included,
    required this.onOpen,
    required this.onDelete,
    super.key,
  });
  // Use InkWell for the full row; destructive delete stays in PopupMenuButton.
}
```

- [ ] **Step 3: Update widget tests to assert project row metadata, opening, overflow deletion, and the empty state.**

```dart
expect(find.text('周末训练赛'), findsOneWidget);
expect(find.textContaining('4 个已保留'), findsOneWidget);
expect(find.byTooltip('项目操作'), findsOneWidget);
```

- [ ] **Step 4: Run the project page tests.**

```bash
cd apps/desktop
HOME="$TMPDIR/courtside-flutter-home" PATH="$PWD/../../.tooling/flutter/bin:$PATH" flutter test test/home_screen_test.dart test/widget_test.dart
```

Expected: all tests pass.

### Task 3: Rebuild import as canvas plus calibration inspector

**Files:**
- Modify: `apps/desktop/lib/features/import_video/import_video_screen.dart`
- Create: `apps/desktop/lib/features/import_video/import_calibration_inspector.dart`
- Test: `apps/desktop/test/import_video_screen_test.dart`

- [ ] **Step 1: Keep `_RoiCanvas` and `_AnalysisRangeEditor` behavior intact, but compose them through a wide `Row` and narrow `Column`.**

```dart
LayoutBuilder(
  builder: (context, constraints) {
    final inspector = ImportCalibrationInspector(...);
    if (constraints.maxWidth >= 1180) {
      return Row(
        children: [
          Expanded(flex: 7, child: _RoiCanvas(...)),
          const SizedBox(width: 16),
          SizedBox(width: 320, child: inspector),
        ],
      );
    }
    return Column(children: [_RoiCanvas(...), const SizedBox(height: 12), inspector]);
  },
);
```

- [ ] **Step 2: Move video picker, video metadata, analysis range, ROI target switch, ROI help, reset, and auto-save state into ordered `InspectorSection`s.**

```dart
InspectorSection(
  title: '分析范围',
  child: _AnalysisRangeEditor(...),
)
```

- [ ] **Step 3: Place `开始分析` in the workspace toolbar and expose the unavailable reason below it instead of a silent disabled action.**

```dart
final canAnalyze = hasVideo && hasRoi && roiSaved && !roiBusy;
CsButton(
  label: const Text('开始分析'),
  onPressed: canAnalyze ? _startAnalysis : null,
)
```

- [ ] **Step 4: Run import tests and static analysis.**

```bash
cd apps/desktop
HOME="$TMPDIR/courtside-flutter-home" PATH="$PWD/../../.tooling/flutter/bin:$PATH" flutter test test/import_video_screen_test.dart
HOME="$TMPDIR/courtside-flutter-home" PATH="$PWD/../../.tooling/flutter/bin:$PATH" flutter analyze
```

Expected: ROI save, range save, and analysis CTA behavior remain covered.

### Task 4: Replace the review queue with a video editor workbench

**Files:**
- Modify: `apps/desktop/lib/features/review/review_screen.dart`
- Create: `apps/desktop/lib/features/review/candidate_filmstrip.dart`
- Create: `apps/desktop/lib/features/review/review_inspector.dart`
- Test: `apps/desktop/test/review_screen_test.dart`

- [ ] **Step 1: Preserve the existing selection, preview queue, shortcuts, and `_VideoPane` state; replace the root wide layout with main canvas, filmstrip, and current-candidate inspector.**

```dart
return CsWorkspace(
  title: videoTitle,
  subtitle: '候选 ${selectedIndex + 1} / ${candidates.length}',
  actions: [exportButton, reanalyzeMenu],
  child: Column(
    children: [
      if (showAnalysisState) _AnalysisBar(...),
      Expanded(child: _VideoPane(...)),
      CandidateFilmstrip(...),
      ReviewInspector(...),
    ],
  ),
);
```

- [ ] **Step 2: Implement `CandidateFilmstrip` as a horizontally scrolling thumbnail strip.**

```dart
class CandidateFilmstrip extends StatelessWidget {
  const CandidateFilmstrip({
    required this.candidates,
    required this.selectedId,
    required this.onSelect,
    required this.onLoadCover,
    super.key,
  });
  // ListView.separated(scrollDirection: Axis.horizontal)
}
```

Each item shows cover, event time, clip duration, and included/excluded state. Clicking invokes the existing `onSelect`; it must not call review status changes.

- [ ] **Step 3: Implement `ReviewInspector` for the selected candidate.**

```dart
ReviewInspector(
  candidate: selected,
  onInclude: () => onSetStatus(selectedId, 'included'),
  onExclude: () => onSetStatus(selectedId, 'excluded'),
  onEditRange: _editClipRange,
  onEditNote: _editCandidateNote,
  onToggleAnnotations: ...,
)
```

It displays summary evidence by default and puts full evidence and shortcut reference behind expandable panels. Include/exclude buttons remain 52×44px and do not change selected candidate.

- [ ] **Step 4: Update the no-candidate and active-analysis layouts so the next action appears within the canvas workspace.**

```dart
CsEmptyState(
  icon: CupertinoIcons.video_camera,
  title: '暂未找到候选片段',
  action: Wrap(children: [reanalyzeButton, adjustRoiButton]),
)
```

- [ ] **Step 5: Extend review tests for the filmstrip and preserve behavioral regressions.**

```dart
expect(find.byType(CandidateFilmstrip), findsOneWidget);
expect(find.text('04:10'), findsOneWidget);
await tester.tap(find.byKey(const ValueKey('candidate-filmstrip-candidate-2')));
expect(find.text('候选 2 / 3'), findsOneWidget);
```

Also retain tests for keyboard navigation, candidate playback range, direct decisions, exclusions without selection changes, evidence, annotations, and no-candidate actions.

- [ ] **Step 6: Run review tests.**

```bash
cd apps/desktop
HOME="$TMPDIR/courtside-flutter-home" PATH="$PWD/../../.tooling/flutter/bin:$PATH" flutter test test/review_screen_test.dart
```

Expected: existing review behaviors and new filmstrip tests pass.

### Task 5: Rebuild export as a compact output inspector

**Files:**
- Modify: `apps/desktop/lib/features/export/export_screen.dart`
- Create: `apps/desktop/lib/components/export_summary.dart`
- Test: `apps/desktop/test/export_screen_test.dart`

- [ ] **Step 1: Use `CsWorkspace` and `ExportSummary` for count, total duration, codec, and execution state.**

```dart
return CsWorkspace(
  title: '导出集锦',
  subtitle: '$includedCount 个片段 · ${_formatMs(durationMs)}',
  child: ExportSummary(
    includedCount: includedCount,
    duration: durationMs,
    running: exportRunning,
    progress: exportProgress,
    onMerge: () => _chooseMerge(context, notifier),
    onSeparate: () => _chooseSeparate(context, notifier),
  ),
);
```

- [ ] **Step 2: Render export history as compact rows with output metadata and an open-directory action.**

```dart
ListView.separated(
  shrinkWrap: true,
  itemBuilder: (_, index) => ExportHistoryRow(item: state.exportHistory[index]),
  separatorBuilder: (_, _) => const Divider(height: 1),
  itemCount: state.exportHistory.length,
)
```

- [ ] **Step 3: Run export tests.**

```bash
cd apps/desktop
HOME="$TMPDIR/courtside-flutter-home" PATH="$PWD/../../.tooling/flutter/bin:$PATH" flutter test test/export_screen_test.dart
```

Expected: merge, separate, cancel/retry, history, and open-directory behavior remain covered.

### Task 6: Visual regression pass and release validation

**Files:**
- Modify: `apps/desktop/test/review_screen_test.dart`
- Modify: `apps/desktop/test/router/app_router_test.dart`
- Verify: `apps/desktop/build/macos/Build/Products/Debug/desktop.app`

- [ ] **Step 1: Add width-constrained widget tests for `1180px` and `1440px` workspace layouts.**

```dart
await tester.binding.setSurfaceSize(const Size(1440, 900));
await tester.pumpWidget(buildReviewApp());
expect(find.byType(CandidateFilmstrip), findsOneWidget);
expect(find.byType(OverflowBar), findsNothing);
```

- [ ] **Step 2: Run full Flutter verification.**

```bash
cd apps/desktop
HOME="$TMPDIR/courtside-flutter-home" PATH="$PWD/../../.tooling/flutter/bin:$PATH" flutter analyze
HOME="$TMPDIR/courtside-flutter-home" PATH="$PWD/../../.tooling/flutter/bin:$PATH" flutter test
HOME="$TMPDIR/courtside-flutter-home" PATH="$PWD/../../.tooling/flutter/bin:$PATH" flutter build macos --debug
```

Expected: `No issues found`, all tests pass, and macOS Debug application builds.

- [ ] **Step 3: Inspect the built app at 1440×900 and 1180×720.**

Verify: no Flutter overflow banner; video canvas is at least 60% of review workbench height; filmstrip scrolls horizontally; all four page layouts use the same workspace shell.

- [ ] **Step 4: Commit the completed redesign.**

```bash
git add apps/desktop/lib apps/desktop/test apps/desktop/pubspec.yaml apps/desktop/pubspec.lock docs/design
git commit -m "feat(ui): 重构桌面编辑器工作台"
```
