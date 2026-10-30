import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/engine_session.dart';
import '../../theme/app_colors.dart';
import '../../theme/tokens.dart';
import 'review_text_entry_dialog.dart';

/// A project-scoped contact sheet. All persistence goes through the engine.
class ShooterQuickLabel extends StatefulWidget {
  const ShooterQuickLabel({
    super.key,
    required this.request,
    this.initialVideoId,
    this.embedded = false,
    this.active = true,
    this.reloadToken = 0,
    this.onWatchClip,
    this.onSavingChanged,
  });

  final Future<JsonMap> Function(String command, JsonMap payload) request;
  final String? initialVideoId;
  final bool embedded, active;
  final int reloadToken;
  final ValueChanged<String>? onWatchClip;
  final ValueChanged<bool>? onSavingChanged;

  @override
  State<ShooterQuickLabel> createState() => _ShooterQuickLabelState();
}

class _ShooterQuickLabelState extends State<ShooterQuickLabel> {
  List<JsonMap> _rows = [], _players = [], _videos = [];
  final _frameChoices = <String, int>{};
  final _saving = <String>{};
  final _undo = <JsonMap>[];
  final _focus = FocusNode();
  String? _activeId, _videoId, _error, _watchingJob;
  JsonMap? _job;
  String _filter = 'all';
  bool _loading = true, _preparing = false, _context = false;
  bool _addingPlayer = false;

  String t(String zh, String en) =>
      Localizations.localeOf(context).languageCode == 'zh' ? zh : en;

  static JsonMap _map(dynamic value) =>
      value is Map ? value.cast<String, dynamic>() : <String, dynamic>{};
  static List<JsonMap> _maps(dynamic value) =>
      value is List ? value.whereType<Map>().map(_map).toList() : [];
  static String _id(JsonMap row) => row['id'].toString();
  static String _time(dynamic ms) {
    final seconds = ((ms as num?)?.toDouble() ?? 0) / 1000;
    return '${seconds ~/ 60}:${(seconds % 60).toStringAsFixed(2).padLeft(5, '0')}';
  }

  bool get _running => ['queued', 'running'].contains(_job?['state']);
  List<JsonMap> get _visible => _rows.where((row) {
    if (_videoId != null && row['video_id'] != _videoId) return false;
    if (_filter == 'pending') return row['shooter_review_state'] == 'pending';
    if (_filter == 'uncertain') {
      if (row['shooter_review_state'] == 'confirmed') return false;
      return row['shooter_review_state'] == 'uncertain' ||
          _map(row['shooter_evidence'])['release_uncertain'] == true ||
          row['shooter_evidence'] == null;
    }
    return true;
  }).toList();

  @override
  void initState() {
    super.initState();
    _videoId = widget.initialVideoId;
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant ShooterQuickLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && widget.reloadToken != oldWidget.reloadToken) {
      unawaited(_load());
    }
    if (widget.active && !oldWidget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  void _notifyBusy() =>
      widget.onSavingChanged?.call(_addingPlayer || _saving.isNotEmpty);

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final result = await widget.request('list_shooter_review', {});
      if (!mounted) return;
      setState(() {
        _rows = _maps(result['candidates']);
        _players = _maps(result['players']);
        _videos = _maps(result['videos']);
        if (!_videos.any((v) => v['id'] == _videoId)) _videoId = null;
        _job = _maps(result['jobs']).firstOrNull;
        _loading = false;
        if (!_visible.any((row) => _id(row) == _activeId)) {
          _activeId = _visible.firstOrNull?['id']?.toString();
        }
      });
      final job = _job;
      if (job != null && _running && _watchingJob != job['id']) {
        unawaited(_watch(job['id'].toString()));
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _watch(String id) async {
    _watchingJob = id;
    var ticks = 0;
    try {
      while (mounted && _watchingJob == id) {
        await Future<void>.delayed(const Duration(seconds: 1));
        if (!mounted || _watchingJob != id) return;
        final result = await widget.request('get_job', {'job_id': id});
        if (!mounted) return;
        setState(() => _job = _map(result['job']));
        if (_running && _job?['type'] == 'analysis' && ++ticks % 2 == 0) {
          await _load();
        }
        if (!_running) {
          _watchingJob = null;
          _frameChoices.clear();
          await _load();
          return;
        }
      }
    } catch (error) {
      _watchingJob = null;
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _prepare() async {
    setState(() {
      _preparing = true;
      _error = null;
    });
    try {
      final result = await widget.request('prepare_shooter_review', {
        if (_videoId != null) 'video_id': _videoId,
      });
      if (!mounted) return;
      setState(() => _job = _map(result['job']));
      unawaited(_watch(_job!['id'].toString()));
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  Future<void> _cancel() async {
    try {
      await widget.request('cancel_job', {'job_id': _job!['id']});
      await _load();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _addPlayer([JsonMap? row]) async {
    if (_addingPlayer || _saving.isNotEmpty) return;
    final name = await promptReviewPlayerName(context);
    if (!mounted || name == null || name.trim().isEmpty) return;
    setState(() => _addingPlayer = true);
    _notifyBusy();
    try {
      final result = await widget.request('create_player', {
        'name': name.trim(),
      });
      final playerId = _map(result['player'])['id']?.toString();
      await _load();
      if (!mounted || row == null || playerId == null) return;
      final current = _rows.where((r) => _id(r) == _id(row)).firstOrNull;
      if (current != null) await _save(current, playerId, 'confirmed');
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() => _addingPlayer = false);
        _notifyBusy();
      }
    }
  }

  List<JsonMap> _frames(JsonMap row) =>
      _maps(_map(row['shooter_evidence'])['frames']);
  int _frameIndex(JsonMap row) {
    final frames = _frames(row);
    if (frames.isEmpty) return 0;
    final selected = _frameChoices[_id(row)];
    if (selected != null) return selected.clamp(0, frames.length - 1).toInt();
    final saved = _map(row['shooter_selection']);
    final evidence = _map(row['shooter_evidence']);
    final time =
        (saved['generation'] == evidence['generation']
                ? saved['time_ms']
                : null)
            as num?;
    if (time == null) {
      return frames.length ~/ 2;
    }
    var best = 0;
    for (var i = 1; i < frames.length; i++) {
      if (((frames[i]['time_ms'] as num) - time).abs() <
          ((frames[best]['time_ms'] as num) - time).abs()) {
        best = i;
      }
    }
    return best;
  }

  Future<void> _save(
    JsonMap row,
    String? playerId,
    String state, {
    JsonMap? restore,
  }) async {
    final id = _id(row),
        frames = _frames(row),
        evidence = _map(row['shooter_evidence']);
    if (_saving.isNotEmpty ||
        evidence.isEmpty ||
        frames.isEmpty ||
        row['draft'] == true) {
      return;
    }
    final frame = frames[_frameIndex(row)];
    final previous = _map(row['shooter_selection']);
    final sameGeneration = previous['generation'] == evidence['generation'];
    final prior = <String, dynamic>{
      'candidate_id': id,
      'generation': evidence['generation'],
      'player_id': row['player_id'],
      'review_state': row['shooter_review_state'],
      'time_ms': sameGeneration ? previous['time_ms'] : null,
    };
    // Ordinary review labels may predate these stills; undo can restore a name
    // without claiming that an evidence frame had already been selected.
    if (prior['player_id'] != null) prior['review_state'] = 'confirmed';
    setState(() {
      _saving.add(id);
      _error = null;
      _activeId = id;
    });
    _notifyBusy();
    try {
      final result = await widget.request('set_candidate_shooter', {
        'candidate_id': id,
        'generation': evidence['generation'],
        'time_ms': frame['time_ms'],
        'player_id': playerId,
        'review_state': state,
        ...?restore,
      });
      if (!mounted) return;
      setState(() {
        if (restore == null) _undo.add(prior);
        row['player_id'] = playerId;
        row['player_name'] = _players
            .where((p) => p['id'] == playerId)
            .firstOrNull?['name'];
        row['shooter_selection'] = result['selection'];
        row['shooter_review_state'] = result['review_state'];
        _frameChoices.remove(id);
        if (!_visible.any((r) => _id(r) == id)) {
          _activeId = _visible.firstOrNull?['id']?.toString();
        }
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() => _saving.remove(id));
        _notifyBusy();
      }
    }
  }

  Future<void> _undoLast() async {
    if (_undo.isEmpty || _saving.isNotEmpty) return;
    final value = _undo.last;
    final row = _rows.where((r) => _id(r) == value['candidate_id']).firstOrNull;
    if (row == null ||
        _map(row['shooter_evidence'])['generation'] != value['generation']) {
      setState(() {
        _undo.clear();
        _error = t(
          '画面已更新，无法撤销旧版本的选择',
          'Evidence changed; old selections cannot be undone',
        );
      });
      return;
    }
    await _save(
      row,
      value['player_id'] as String?,
      value['review_state'] as String,
      restore: value,
    );
    if (mounted && _error == null) setState(() => _undo.removeLast());
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (!widget.active ||
        event is! KeyDownEvent ||
        _saving.isNotEmpty ||
        _addingPlayer) {
      return KeyEventResult.ignored;
    }
    final index = const [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.digit8,
      LogicalKeyboardKey.digit9,
    ].indexOf(event.logicalKey);
    final row = _visible.where((r) => _id(r) == _activeId).firstOrNull;
    if (index >= 0 && index < _players.length && row != null) {
      unawaited(_save(row, _players[index]['id'].toString(), 'confirmed'));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final visible = _visible;
    final completed = _rows
        .where((r) => r['shooter_review_state'] == 'confirmed')
        .length;
    return ExcludeFocus(
      excluding: !widget.active,
      child: Focus(
        focusNode: _focus,
        autofocus: widget.active,
        onKeyEvent: _key,
        child: Scaffold(
          backgroundColor: c.background,
          appBar: widget.embedded
              ? null
              : AppBar(
                  title: Text(t('射手快标', 'Shooter quick label')),
                  leading: IconButton(
                    tooltip: t('返回审核', 'Back to review'),
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
          body: Column(
            children: [
              Container(
                width: double.infinity,
                color: c.surface,
                padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.md,
                  vertical: Spacing.sm,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: Spacing.sm,
                      runSpacing: Spacing.xs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          t(
                            '已标 $completed / ${_rows.length}',
                            'Labeled $completed / ${_rows.length}',
                          ),
                          style: TextStyle(color: c.textSecondary),
                        ),
                        DropdownButton<String>(
                          value: _videos.any((v) => v['id'] == _videoId)
                              ? _videoId
                              : 'all',
                          isDense: true,
                          items: [
                            DropdownMenuItem(
                              value: 'all',
                              child: Text(t('全部视频', 'All videos')),
                            ),
                            for (var i = 0; i < _videos.length; i++)
                              DropdownMenuItem(
                                value: _videos[i]['id'].toString(),
                                child: Text(
                                  t('第 ${i + 1} 段', 'Video ${i + 1}'),
                                ),
                              ),
                          ],
                          onChanged: (value) => setState(() {
                            _videoId = value == 'all' ? null : value;
                            _activeId = null;
                          }),
                        ),
                        for (final option in ['all', 'pending', 'uncertain'])
                          ChoiceChip(
                            label: Text(
                              option == 'all'
                                  ? t('全部', 'All')
                                  : option == 'pending'
                                  ? t('待标注', 'Pending')
                                  : t('需核实', 'Uncertain'),
                            ),
                            selected: _filter == option,
                            selectedColor: c.orange.withValues(alpha: .14),
                            backgroundColor: c.surface2,
                            labelStyle: TextStyle(
                              color: _filter == option
                                  ? c.orange
                                  : c.textSecondary,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(CsRadius.sm),
                            ),
                            onSelected: (_) => setState(() => _filter = option),
                          ),
                        FilterChip(
                          label: Text(t('显示全景蓝框', 'Show full frame')),
                          selected: _context,
                          selectedColor: c.orange.withValues(alpha: .14),
                          labelStyle: TextStyle(
                            color: _context ? c.orange : c.textSecondary,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(CsRadius.sm),
                          ),
                          onSelected: (v) => setState(() => _context = v),
                        ),
                        OutlinedButton.icon(
                          onPressed: _running || _preparing
                              ? null
                              : () => _prepare(),
                          icon: const Icon(
                            Icons.photo_library_outlined,
                            size: 18,
                          ),
                          label: Text(t('补齐/刷新画面', 'Refresh stills')),
                        ),
                        TextButton.icon(
                          onPressed: _addingPlayer || _saving.isNotEmpty
                              ? null
                              : () => _addPlayer(),
                          icon: const Icon(Icons.person_add_alt_1, size: 18),
                          label: Text(t('添加球员', 'Add player')),
                        ),
                        TextButton.icon(
                          onPressed: _undo.isEmpty || _saving.isNotEmpty
                              ? null
                              : _undoLast,
                          icon: const Icon(Icons.undo, size: 18),
                          label: Text(t('撤销', 'Undo')),
                        ),
                        IconButton(
                          tooltip: t('刷新', 'Refresh'),
                          onPressed: _load,
                          icon: const Icon(Icons.refresh, size: 20),
                        ),
                      ],
                    ),
                    Text(
                      t(
                        '看中间帧认人，点击姓名保存；前后帧按需切换。数字 1–9 标记当前卡片。',
                        'Choose a name using the middle frame; switch adjacent frames when needed. Keys 1–9 label the selected card.',
                      ),
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: c.textSecondary),
                    ),
                    if (_running || _preparing) ...[
                      const SizedBox(height: Spacing.sm),
                      LinearProgressIndicator(
                        value: _preparing
                            ? null
                            : ((_job?['progress'] as num?)?.toDouble() ?? 0)
                                  .clamp(0, 1),
                        color: c.orange,
                        backgroundColor: c.surface3,
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _job?['type'] == 'analysis'
                                  ? t(
                                      '分析中：出手画面会陆续出现，完成后可标注射手。',
                                      'Analysis in progress: release stills appear here; label shooters after completion.',
                                    )
                                  : t(
                                      '正在准备出手画面，原有标签保留。',
                                      'Preparing frames; existing labels are preserved.',
                                    ),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          TextButton(
                            onPressed: _running ? _cancel : null,
                            child: Text(t('取消任务', 'Cancel task')),
                          ),
                        ],
                      ),
                    ],
                    if (_error != null || _job?['state'] == 'failed')
                      Padding(
                        padding: const EdgeInsets.only(top: Spacing.xs),
                        child: SelectableText(
                          _error ?? _job?['error_message']?.toString() ?? '',
                          style: TextStyle(color: c.error),
                        ),
                      ),
                  ],
                ),
              ),
              Divider(height: 1, color: c.border),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : visible.isEmpty
                    ? Center(
                        child: Text(
                          t('当前筛选下没有片段', 'No clips match this filter'),
                        ),
                      )
                    : LayoutBuilder(
                        builder: (context, size) {
                          final columns = size.maxWidth >= Breakpoints.md
                              ? 5
                              : size.maxWidth >= 600
                              ? 2
                              : 1;
                          final cardWidth =
                              (size.maxWidth -
                                  Spacing.md * 2 -
                                  12 * (columns - 1)) /
                              columns;
                          final imageHeight = (cardWidth - 20) * 4 / 3;
                          final scale =
                              (MediaQuery.textScalerOf(context).scale(13) / 13)
                                  .clamp(1.0, 2.0);
                          return GridView.builder(
                            key: const Key('shooter-card-grid'),
                            padding: const EdgeInsets.all(Spacing.md),
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: columns,
                                  mainAxisExtent:
                                      imageHeight + 220 * scale,
                                  mainAxisSpacing: 12,
                                  crossAxisSpacing: 12,
                                ),
                            itemCount: visible.length,
                            itemBuilder: (context, index) => _card(
                              visible[index],
                              _rows.indexOf(visible[index]) + 1,
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _image(String? path, {BoxFit fit = BoxFit.contain}) => path == null
      ? Center(
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Text(
              t('暂无出手画面', 'No release frame'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11),
            ),
          ),
        )
      : Image.file(
          File(path),
          fit: fit,
          gaplessPlayback: true,
          errorBuilder: (_, error, stack) => Center(
            child: Text(
              t('图片不可用，请刷新画面', 'Image unavailable; refresh stills'),
              textAlign: TextAlign.center,
            ),
          ),
        );

  void _selectFrame(JsonMap row, int index) {
    setState(() {
      _activeId = _id(row);
      _frameChoices[_id(row)] = index;
    });
    _focus.requestFocus();
  }

  Widget _framePreview(JsonMap row, JsonMap frame, int index) {
    final c = AppColors.of(context);
    final id = _id(row), evidence = _map(row['shooter_evidence']);
    final focus = _map(frame['focus_region']);
    final cropPath = focus['crop_path'];
    final path =
        (_context ? frame['context_path'] : cropPath ?? frame['context_path'])
            as String?;
    final zoom =
        !_context &&
            cropPath != null &&
            evidence['reason'] == 'upward_ball_motion_estimate'
        ? 1.12
        : 1.0;
    final hasRegion = !_context && cropPath != null;
    return Semantics(
      image: true,
      label: t(
        '第 ${index + 1} 帧，${_time(frame['time_ms'])}',
        'Frame ${index + 1}, ${_time(frame['time_ms'])}',
      ),
      child: Container(
        key: ValueKey('shooter-preview-$id-$index'),
        decoration: BoxDecoration(
          color: Colors.black,
          border: Border.all(color: c.borderStrong),
          borderRadius: BorderRadius.circular(CsRadius.sm),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRect(
              child: Transform.scale(
                key: ValueKey('shooter-frame-zoom-$id-$index'),
                scale: zoom,
                child: SizedBox.expand(child: _image(path)),
              ),
            ),
            Positioned(
              left: 6,
              top: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: c.background.withValues(alpha: .82),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  hasRegion ? t('出手区域', 'Release area') : t('全景', 'Full frame'),
                  style: TextStyle(
                    fontSize: 10,
                    color: hasRegion ? c.data : c.textSecondary,
                  ),
                ),
              ),
            ),
            Positioned(
              right: 6,
              top: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: c.background.withValues(alpha: .82),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '${index + 1} / ${_frames(row).length}',
                  style: TextStyle(fontSize: 10, color: c.textSecondary),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _frameLabel(int index, int count) {
    final middle = count ~/ 2;
    if (index == middle) return t('中间帧', 'Middle');
    return index < middle ? t('前一帧', 'Previous') : t('后一帧', 'Next');
  }

  Widget _framePicker(JsonMap row) {
    final c = AppColors.of(context);
    final id = _id(row), frames = _frames(row);
    return SizedBox(
      height: 30,
      child: Row(
        key: ValueKey('shooter-frames-$id'),
        children: [
          for (var i = 0; i < frames.length; i++) ...[
            if (i > 0) const SizedBox(width: 3),
            Expanded(
              child: Semantics(
                selected: i == _frameIndex(row),
                child: Tooltip(
                  message:
                      '${_frameLabel(i, frames.length)} · ${_time(frames[i]['time_ms'])}',
                  child: TextButton(
                    key: ValueKey('shooter-frame-$id-$i'),
                    onPressed: () => _selectFrame(row, i),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      minimumSize: const Size(24, 28),
                      foregroundColor: i == _frameIndex(row)
                          ? c.orange
                          : c.textSecondary,
                      backgroundColor: i == _frameIndex(row)
                          ? c.orange.withValues(alpha: .14)
                          : c.surface2,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                      textStyle: const TextStyle(fontSize: 10),
                    ),
                    child: Text(
                      _frameLabel(i, frames.length),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _card(JsonMap row, int number) {
    final c = AppColors.of(context);
    final id = _id(row),
        evidence = _map(row['shooter_evidence']),
        frames = _frames(row);
    final frame = frames.isEmpty
        ? <String, dynamic>{}
        : frames[_frameIndex(row)];
    final draft = row['draft'] == true;
    final state = row['shooter_review_state'];
    final canSave =
        evidence.isNotEmpty &&
        frames.isNotEmpty &&
        !draft &&
        _saving.isEmpty &&
        !_addingPlayer;
    final active = _activeId == id;
    return Card(
      key: ValueKey('shooter-card-$id'),
      margin: EdgeInsets.zero,
      color: c.surface,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CsRadius.md),
        side: BorderSide(
          color: active ? c.orange : c.border,
          width: active ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        onTap: () {
          setState(() => _activeId = id);
          _focus.requestFocus();
        },
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '#$number  ${_time(row['event_time_ms'])}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.titleSmall?.copyWith(color: c.textPrimary),
                    ),
                  ),
                  Text(
                    draft
                        ? t('分析中预览', 'Analysis preview')
                        : state == 'confirmed'
                        ? t('已保存', 'Saved')
                        : state == 'uncertain'
                        ? t('不确定', 'Uncertain')
                        : t('待标注', 'Pending'),
                    style: TextStyle(
                      fontSize: 11,
                      color: state == 'confirmed' ? c.success : c.textSecondary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              AspectRatio(
                key: ValueKey('shooter-photo-$id'),
                aspectRatio: 3 / 4,
                child: frames.isEmpty
                    ? _image(null)
                    : _framePreview(row, frame, _frameIndex(row)),
              ),
              if (frames.isNotEmpty) ...[
                const SizedBox(height: 4),
                _framePicker(row),
              ],
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      row['player_name'] == null
                          ? t('点击名字保存射手', 'Choose a name to save')
                          : t(
                              '射手：${row['player_name']}',
                              'Shooter: ${row['player_name']}',
                            ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: c.textPrimary),
                    ),
                  ),
                  TextButton.icon(
                    key: ValueKey('shooter-add-player-$id'),
                    onPressed: _addingPlayer || _saving.isNotEmpty
                        ? null
                        : () => _addPlayer(row),
                    icon: const Icon(Icons.person_add_alt_1, size: 15),
                    label: Text(t('添加球员', 'Add player')),
                    style: TextButton.styleFrom(
                      foregroundColor: c.orange,
                      minimumSize: const Size(44, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      textStyle: const TextStyle(fontSize: 11),
                    ),
                  ),
                ],
              ),
              Expanded(
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (var i = 0; i < _players.length; i++)
                        FilledButton.tonal(
                          key: ValueKey(
                            'shooter-name-$id-${_players[i]['id']}',
                          ),
                          onPressed: canSave
                              ? () => _save(
                                  row,
                                  _players[i]['id'].toString(),
                                  'confirmed',
                                )
                              : null,
                          style: FilledButton.styleFrom(
                            backgroundColor:
                                row['player_id'] == _players[i]['id']
                                ? c.orange.withValues(alpha: .16)
                                : c.surface2,
                            foregroundColor:
                                row['player_id'] == _players[i]['id']
                                ? c.orange
                                : c.textPrimary,
                            minimumSize: const Size(44, 32),
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(CsRadius.sm),
                            ),
                            visualDensity: VisualDensity.compact,
                            textStyle: const TextStyle(fontSize: 12),
                          ),
                          child: Text(
                            '${_players[i]['name']}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      if (_players.isEmpty)
                        Text(
                          t('添加球员后即可标注', 'Add players to start labeling'),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: c.textSecondary),
                        ),
                    ],
                  ),
                ),
              ),
              Wrap(
                spacing: 4,
                children: [
                  TextButton(
                    onPressed: canSave
                        ? () => _save(row, null, 'uncertain')
                        : null,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(44, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      textStyle: const TextStyle(fontSize: 11),
                    ),
                    child: Text(t('不确定', 'Uncertain')),
                  ),
                  TextButton(
                    onPressed: canSave
                        ? () => _save(row, null, 'pending')
                        : null,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(44, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      textStyle: const TextStyle(fontSize: 11),
                    ),
                    child: Text(t('清除', 'Clear')),
                  ),
                  TextButton.icon(
                    onPressed: _saving.isEmpty && !_addingPlayer && !draft
                        ? () {
                            if (widget.onWatchClip case final watch?) {
                              watch(id);
                            } else {
                              Navigator.pop(context, id);
                            }
                          }
                        : null,
                    icon: const Icon(Icons.play_circle_outline, size: 16),
                    label: Text(t('看视频', 'Watch clip')),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(44, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      textStyle: const TextStyle(fontSize: 11),
                    ),
                  ),
                ],
              ),
              Text(
                row['shooter_evidence_stale'] == true
                    ? t('源视频已变化，请刷新画面', 'Source changed; refresh stills')
                    : row['selection_status'] == 'excluded'
                    ? t(
                        '片段已排除 · 射手仍可标注',
                        'Excluded clip · shooter can still be labeled',
                      )
                    : t(
                        '出手区域为估计 · 射手独立保存',
                        'Approximate release area · shooter saved separately',
                      ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontSize: 10,
                  color: c.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
