# Existing Video Merge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (\`- [ ]\`) syntax for tracking.

**Goal:** Add an Export-page dialog that lets users select, order, and merge existing local videos into one MP4 without creating or analysing a project.

**Architecture:** The dialog sends ordered input paths and an output path to a project-independent Engine command. A reusable exporter validates paths, writes an FFmpeg concat manifest, tries stream copy first, then applies the established encoder fallback policy. The command returns after FFmpeg completes and never creates a project export record.

**Tech Stack:** Flutter/Dart, Riverpod, file_selector, Python JSONL Engine, FFmpeg/FFprobe, pytest, flutter_test.

---

## File Structure

- \`engine/python/basketball_engine/adapters/export.py\`: external-input merge and atomic output.
- \`engine/python/basketball_engine/service.py\`: \`merge_existing_videos\` Engine command.
- \`tests/test_export_adapter.py\` and \`tests/test_engine.py\`: Python behavior coverage.
- \`apps/desktop/lib/core/engine_session.dart\`: typed Engine request wrapper.
- \`apps/desktop/lib/providers/export_output_picker.dart\`: replaceable video/output picker boundary.
- \`apps/desktop/lib/features/export/existing_video_merge_dialog.dart\`: dialog state and controls.
- \`apps/desktop/lib/features/export/export_screen.dart\`: Export-page entry.
- \`apps/desktop/test/existing_video_merge_dialog_test.dart\`: dialog behavior coverage.
- \`apps/desktop/test/export_screen_test.dart\` and \`apps/desktop/test/engine_session_test.dart\`: entry and request coverage.

### Task 1: Add a reusable Python merge operation

**Files:**
- Modify: \`engine/python/basketball_engine/adapters/export.py\`
- Test: \`tests/test_export_adapter.py\`

- [ ] **Step 1: Write failing tests for ordered concat, re-encoding fallback, and invalid paths.**

\`\`\`python
from engine.python.basketball_engine.adapters.export import merge_existing_videos

def test_merge_existing_videos_uses_input_order_and_stream_copy(tmp_path, monkeypatch):
    first, second, output = (tmp_path / "first.mp4", tmp_path / "second.mp4", tmp_path / "merged.mp4")
    first.write_bytes(b"first")
    second.write_bytes(b"second")
    commands = []
    def fake_ffmpeg(command, output_path, **_kwargs):
        commands.append(command)
        output_path.write_bytes(b"merged")
    monkeypatch.setattr(export, "run_atomic_ffmpeg", fake_ffmpeg)
    result = merge_existing_videos([first, second], output)
    manifest = Path(commands[0][commands[0].index("-i") + 1])
    assert manifest.read_text(encoding="utf-8") == concat_manifest_entry(first) + concat_manifest_entry(second)
    assert commands[0][commands[0].index("-c") + 1] == "copy"
    assert result["files"] == [str(output)]

def test_merge_existing_videos_reencodes_after_stream_copy_failure(tmp_path, monkeypatch):
    source, output = tmp_path / "first.mp4", tmp_path / "merged.mp4"
    source.write_bytes(b"first")
    attempts = []
    def fake_ffmpeg(command, output_path, **_kwargs):
        attempts.append(command)
        if command[command.index("-c") + 1] == "copy":
            raise subprocess.CalledProcessError(1, command)
        output_path.write_bytes(b"merged")
    monkeypatch.setattr(export, "run_atomic_ffmpeg", fake_ffmpeg)
    monkeypatch.setattr(export, "video_codecs", lambda: ["mpeg4"])
    merge_existing_videos([source], output)
    assert attempts[1][attempts[1].index("-c:v") + 1] == "mpeg4"

def test_merge_existing_videos_rejects_empty_missing_and_output_conflicts(tmp_path):
    source = tmp_path / "source.mp4"
    source.write_bytes(b"source")
    with pytest.raises(ValueError, match="NO_MERGE_INPUTS"):
        merge_existing_videos([], tmp_path / "out.mp4")
    with pytest.raises(OSError, match="MERGE_INPUT_NOT_FOUND"):
        merge_existing_videos([tmp_path / "missing.mp4"], tmp_path / "out.mp4")
    with pytest.raises(ValueError, match="MERGE_OUTPUT_CONFLICT"):
        merge_existing_videos([source], source)
\`\`\`

- [ ] **Step 2: Verify RED.**

Run: \`..\\.venv\\Scripts\\python.exe -m pytest tests/test_export_adapter.py -k merge_existing_videos -v\`

Expected: import/collection error because \`merge_existing_videos\` does not exist.

- [ ] **Step 3: Implement \`merge_existing_videos(input_paths, output_path, *, cancel_check=None, process_callback=None)\`.**

It must:
1. reject no inputs with \`ValueError("NO_MERGE_INPUTS")\`;
2. resolve all paths and reject absent or empty input files with \`OSError("MERGE_INPUT_NOT_FOUND")\`;
3. reject an output equal to any input with \`ValueError("MERGE_OUTPUT_CONFLICT")\`;
4. write a temporary concat manifest using the existing \`concat_manifest_entry\`;
5. call \`run_atomic_ffmpeg\` first with \`-f concat -safe 0 -i <manifest> -c copy\`;
6. on \`OSError\` or \`CalledProcessError\`, call \`run_encoded_ffmpeg\` with the existing \`video_codecs\`, \`video_codec_options\`, AAC audio, and \`+faststart\`;
7. delete the manifest in \`finally\`; and
8. return \`{"files": [str(output)]}\`.

- [ ] **Step 4: Verify GREEN.**

Run: \`..\\.venv\\Scripts\\python.exe -m pytest tests/test_export_adapter.py -k merge_existing_videos -v\`

Expected: 3 passed.

- [ ] **Step 5: Commit this task.**

\`\`\`bash
git add engine/python/basketball_engine/adapters/export.py tests/test_export_adapter.py
git commit -m "feat: merge existing videos in exporter"
\`\`\`

### Task 2: Add a project-independent Engine command

**Files:**
- Modify: \`engine/python/basketball_engine/service.py\`
- Test: \`tests/test_engine.py\`

- [ ] **Step 1: Write failing command tests.**

\`\`\`python
def test_merge_existing_videos_forwards_ordered_paths(monkeypatch, tmp_path):
    service = EngineService()
    first, second, output = tmp_path / "first.mp4", tmp_path / "second.mp4", tmp_path / "out.mp4"
    first.write_bytes(b"first")
    second.write_bytes(b"second")
    received = {}
    def fake_merge(paths, target):
        received["paths"], received["target"] = paths, target
        return {"files": [str(target)]}
    monkeypatch.setattr("engine.python.basketball_engine.service.merge_existing_videos", fake_merge)
    result = service.handle("merge_existing_videos", {"input_paths": [str(first), str(second)], "output_path": str(output)})
    assert received["paths"] == [first.resolve(), second.resolve()]
    assert result == {"files": [str(output.resolve())]}

def test_merge_existing_videos_requires_input_list_and_output():
    service = EngineService()
    with pytest.raises(ProtocolError, match="input_paths"):
        service.handle("merge_existing_videos", {"input_paths": "bad", "output_path": "out.mp4"})
    with pytest.raises(ProtocolError, match="output_path"):
        service.handle("merge_existing_videos", {"input_paths": ["one.mp4"]})
\`\`\`

- [ ] **Step 2: Verify RED.**

Run: \`..\\.venv\\Scripts\\python.exe -m pytest tests/test_engine.py -k merge_existing_videos -v\`

Expected: failures report unsupported \`merge_existing_videos\`.

- [ ] **Step 3: Add the handler map entry and method.**

Import \`merge_existing_videos\` beside \`export_goal_clips\`; add \`"merge_existing_videos": self.merge_existing_videos\` to \`_handlers\`; then implement a method that validates a non-empty \`list[str]\` named \`input_paths\`, validates a non-empty string \`output_path\`, converts them to \`Path\`, calls the exporter, and converts \`OSError\`, \`ValueError\`, and \`CalledProcessError\` to \`ProtocolError("MERGE_FAILED", f"视频合并失败: {exc}")\`.

- [ ] **Step 4: Verify GREEN.**

Run: \`..\\.venv\\Scripts\\python.exe -m pytest tests/test_engine.py -k merge_existing_videos -v\`

Expected: 2 passed.

- [ ] **Step 5: Commit this task.**

\`\`\`bash
git add engine/python/basketball_engine/service.py tests/test_engine.py
git commit -m "feat: expose existing video merge command"
\`\`\`

### Task 3: Add desktop request and picker boundaries

**Files:**
- Modify: \`apps/desktop/lib/core/engine_session.dart\`
- Modify: \`apps/desktop/lib/providers/export_output_picker.dart\`
- Test: \`apps/desktop/test/engine_session_test.dart\`

- [ ] **Step 1: Write a failing Engine-session test.**

\`\`\`dart
test('mergeExistingVideos sends ordered inputs and output path', () async {
  final transport = _FakeTransport();
  final session = EngineSession(transport);
  await session.mergeExistingVideos(
    inputPaths: const ['/tmp/a.mp4', '/tmp/b.mp4'],
    outputPath: '/tmp/merged.mp4',
  );
  expect(transport.command, 'merge_existing_videos');
  expect(transport.payload, {
    'input_paths': ['/tmp/a.mp4', '/tmp/b.mp4'],
    'output_path': '/tmp/merged.mp4',
  });
});
\`\`\`

- [ ] **Step 2: Verify RED.**

Run: \`C:\\flutter\\bin\\flutter.bat test test/engine_session_test.dart --plain-name "mergeExistingVideos sends ordered inputs and output path"\`

Expected: compilation error because \`mergeExistingVideos\` is absent.

- [ ] **Step 3: Implement the minimal wrapper and picker API.**

Add to \`EngineSession\`:

\`\`\`dart
Future<JsonMap> mergeExistingVideos({
  required List<String> inputPaths,
  required String outputPath,
}) => client.request('merge_existing_videos', <String, dynamic>{
  'input_paths': inputPaths,
  'output_path': outputPath,
});
\`\`\`

Add to \`ExportOutputPicker\`: \`Future<List<String>> existingVideos({required String typeLabel})\`, using \`openFiles\` with \`mp4/mov/mkv/avi\`; and \`Future<String?> existingVideosMergedPath({required String typeLabel})\`, using \`getSaveLocation\` with suggested name \`merged-videos.mp4\` and MP4-only output.

- [ ] **Step 4: Verify GREEN.**

Run: \`C:\\flutter\\bin\\flutter.bat test test/engine_session_test.dart --plain-name "mergeExistingVideos sends ordered inputs and output path"\`

Expected: PASS.

- [ ] **Step 5: Commit this task.**

\`\`\`bash
git add apps/desktop/lib/core/engine_session.dart apps/desktop/lib/providers/export_output_picker.dart apps/desktop/test/engine_session_test.dart
git commit -m "feat: add existing video merge boundary"
\`\`\`

### Task 4: Add the Export-page dialog

**Files:**
- Create: \`apps/desktop/lib/features/export/existing_video_merge_dialog.dart\`
- Modify: \`apps/desktop/lib/features/export/export_screen.dart\`
- Create: \`apps/desktop/test/existing_video_merge_dialog_test.dart\`
- Modify: \`apps/desktop/test/export_screen_test.dart\`

- [ ] **Step 1: Write failing widget tests.**

\`\`\`dart
testWidgets('merge dialog reorders selected videos before dispatch', (tester) async {
  final picker = _MergePicker(files: ['/tmp/first.mp4', '/tmp/second.mp4']);
  final transport = _FakeTransport();
  await pumpMergeDialog(tester, picker: picker, transport: transport);
  await tester.tap(find.text('选择视频'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('existing-video-up-1')));
  await tester.tap(find.text('选择保存位置'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('existing-video-merge-start')));
  expect(transport.payload['input_paths'], ['/tmp/second.mp4', '/tmp/first.mp4']);
  expect(transport.payload['output_path'], '/tmp/merged.mp4');
});

testWidgets('merge button stays disabled until inputs and output exist', (tester) async {
  await pumpMergeDialog(tester, picker: _MergePicker());
  expect(tester.widget<CsButton>(find.byKey(const Key('existing-video-merge-start'))).onPressed, isNull);
});
\`\`\`

Also add an Export-screen test that taps key \`existing-video-merge-open\` and finds \`合并已有视频\`.

- [ ] **Step 2: Verify RED.**

Run: \`C:\\flutter\\bin\\flutter.bat test test/existing_video_merge_dialog_test.dart\`

Expected: test compilation fails because the dialog does not exist.

- [ ] **Step 3: Implement \`ExistingVideoMergeDialog\`.**

Make it a \`ConsumerStatefulWidget\` that owns \`List<String> _inputPaths\`, \`String? _outputPath\`, \`bool _running\`, and \`String? _error\`. Its list offers up/down/remove controls; edge movement controls are disabled. The merge button is enabled only when inputs and output exist and it is not already running. It calls \`EngineSession.mergeExistingVideos\`, preserves selection on errors, displays \`合并失败：<error>\`, and closes only after success.

- [ ] **Step 4: Add the Export-screen entry.**

Add a secondary \`CsButton\` with key \`existing-video-merge-open\` near the Export-page heading. It opens \`ExistingVideoMergeDialog\` with \`showDialog\`; after a true result, show the existing success notice pattern. Do not require a current video or change candidate export state.

- [ ] **Step 5: Verify GREEN.**

Run: \`C:\\flutter\\bin\\flutter.bat test test/existing_video_merge_dialog_test.dart test/export_screen_test.dart\`

Expected: PASS.

- [ ] **Step 6: Commit this task.**

\`\`\`bash
git add apps/desktop/lib/features/export/existing_video_merge_dialog.dart apps/desktop/lib/features/export/export_screen.dart apps/desktop/test/existing_video_merge_dialog_test.dart apps/desktop/test/export_screen_test.dart
git commit -m "feat: add existing video merge dialog"
\`\`\`

### Task 5: Regression verification

**Files:** Verify only.

- [ ] **Step 1: Run Python regression tests.**

Run: \`..\\.venv\\Scripts\\python.exe -m pytest tests/test_export_adapter.py tests/test_engine.py -v\`

Expected: zero failures.

- [ ] **Step 2: Run desktop regression tests.**

Run: \`C:\\flutter\\bin\\flutter.bat test test/engine_session_test.dart test/export_screen_test.dart test/existing_video_merge_dialog_test.dart\`

Expected: zero failures.

- [ ] **Step 3: Build the Windows application.**

Run: \`C:\\flutter\\bin\\flutter.bat build windows --debug\`

Expected: \`√ Built build\\windows\\x64\\runner\\Debug\\BHE.exe\`.

- [ ] **Step 4: Check final repository state.**

Run: \`git diff --check\` then \`git status --short\`.

Expected: no whitespace errors; pre-existing user changes remain untouched.
