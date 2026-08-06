import 'package:flutter/material.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    required this.onNewProject,
    required this.onReview,
    this.onOpenProject,
    this.onLoadRecentProjects,
    this.onOpenRecentProject,
    this.recentProjects = const [],
    this.recentProjectsLoading = false,
    this.recentProjectsError,
    this.goalCount = 0,
    this.pendingCount = 0,
    this.videoDurationMs = 0,
    this.hasProject = false,
    super.key,
  });

  final VoidCallback onNewProject;
  final VoidCallback onReview;
  final Future<void> Function()? onOpenProject;
  final Future<void> Function()? onLoadRecentProjects;
  final Future<void> Function(String projectRoot)? onOpenRecentProject;
  final List<Map<String, dynamic>> recentProjects;
  final bool recentProjectsLoading;
  final String? recentProjectsError;
  final int goalCount;
  final int pendingCount;
  final int videoDurationMs;
  final bool hasProject;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _loadInFlight = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadRecentProjects());
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.onLoadRecentProjects == null &&
        widget.onLoadRecentProjects != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _loadRecentProjects(),
      );
    }
  }

  Future<void> _loadRecentProjects() async {
    final callback = widget.onLoadRecentProjects;
    if (callback == null || _loadInFlight) return;
    setState(() {
      _loadInFlight = true;
      _loadError = null;
    });
    try {
      await callback();
    } catch (error) {
      if (mounted) setState(() => _loadError = error.toString());
    } finally {
      if (mounted) setState(() => _loadInFlight = false);
    }
  }

  Future<void> _openRecentProject(String projectRoot) async {
    final callback = widget.onOpenRecentProject;
    if (callback == null || _loadInFlight) return;
    setState(() {
      _loadInFlight = true;
      _loadError = null;
    });
    try {
      await callback(projectRoot);
    } catch (error) {
      if (mounted) setState(() => _loadError = error.toString());
    } finally {
      if (mounted) setState(() => _loadInFlight = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = widget.recentProjectsError ?? _loadError;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 30, 32, 42),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1280),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '把整场比赛，变成你的高光。',
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              const SizedBox(height: 10),
              Text(
                '固定机位篮球视频 · 本地分析 · 人工审核 · 精确导出',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 28),
              LayoutBuilder(
                builder: (context, constraints) {
                  final stacked = constraints.maxWidth < 850;
                  final intro = _IntroCard(
                    onNewProject: widget.onNewProject,
                    onOpenProject: widget.onOpenProject,
                  );
                  final metrics = _MetricsCard(
                    goalCount: widget.goalCount,
                    pendingCount: widget.pendingCount,
                    videoDurationMs: widget.videoDurationMs,
                    hasProject: widget.hasProject,
                  );
                  return stacked
                      ? Column(
                          children: [
                            intro,
                            const SizedBox(height: 16),
                            metrics,
                          ],
                        )
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(flex: 3, child: intro),
                            const SizedBox(width: 16),
                            Expanded(child: metrics),
                          ],
                        );
                },
              ),
              const SizedBox(height: 28),
              _RecentProjectsSection(
                projects: widget.recentProjects,
                loading: widget.recentProjectsLoading || _loadInFlight,
                error: error,
                canOpen: widget.onOpenRecentProject != null,
                onRefresh: widget.onLoadRecentProjects == null
                    ? null
                    : _loadRecentProjects,
                onOpen: _openRecentProject,
              ),
              const SizedBox(height: 28),
              Text('工作流', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 14),
              const _WorkflowCard(),
              const SizedBox(height: 28),
              OutlinedButton.icon(
                onPressed: widget.onReview,
                icon: const Icon(Icons.play_circle_outline),
                label: const Text('查看审核工作台'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IntroCard extends StatelessWidget {
  const _IntroCard({required this.onNewProject, required this.onOpenProject});
  final VoidCallback onNewProject;
  final Future<void> Function()? onOpenProject;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              children: [
                Icon(Icons.auto_awesome, color: scheme.primary),
                const SizedBox(width: 10),
                Text('从视频开始', style: Theme.of(context).textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              '导入一段长视频，选择篮筐区域，系统会先快速扫描，再把疑似进球交给你确认。',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 22),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  onPressed: onNewProject,
                  icon: const Icon(Icons.add),
                  label: const Text('新建项目'),
                ),
                OutlinedButton.icon(
                  onPressed: onOpenProject,
                  icon: const Icon(Icons.folder_open_outlined),
                  label: const Text('打开项目'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricsCard extends StatelessWidget {
  const _MetricsCard({
    required this.goalCount,
    required this.pendingCount,
    required this.videoDurationMs,
    required this.hasProject,
  });

  final int goalCount;
  final int pendingCount;
  final int videoDurationMs;
  final bool hasProject;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('当前项目', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 20),
            _MetricRow(label: '已确认进球', value: '$goalCount'),
            _MetricRow(label: '待审核片段', value: '$pendingCount'),
            _MetricRow(label: '视频时长', value: _formatDuration(videoDurationMs)),
            const SizedBox(height: 16),
            Text(
              hasProject ? '当前数据来自本地 SQLite 项目' : '还没有打开项目',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecentProjectsSection extends StatelessWidget {
  const _RecentProjectsSection({
    required this.projects,
    required this.loading,
    required this.error,
    required this.canOpen,
    required this.onRefresh,
    required this.onOpen,
  });

  final List<Map<String, dynamic>> projects;
  final bool loading;
  final String? error;
  final bool canOpen;
  final Future<void> Function()? onRefresh;
  final Future<void> Function(String projectRoot) onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('最近项目', style: Theme.of(context).textTheme.titleLarge),
            const Spacer(),
            if (onRefresh != null)
              IconButton(
                tooltip: '刷新最近项目',
                onPressed: loading ? null : onRefresh,
                icon: loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (error != null)
          Card(
            color: scheme.errorContainer,
            child: ListTile(
              leading: Icon(
                Icons.error_outline,
                color: scheme.onErrorContainer,
              ),
              title: Text(
                '最近项目加载失败',
                style: TextStyle(color: scheme.onErrorContainer),
              ),
              subtitle: Text(
                error!,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
              trailing: onRefresh == null
                  ? null
                  : TextButton(
                      onPressed: loading ? null : onRefresh,
                      child: const Text('重试'),
                    ),
            ),
          )
        else if (loading && projects.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Row(
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  Text('正在加载最近项目…'),
                ],
              ),
            ),
          )
        else if (projects.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Row(
                children: [
                  Icon(Icons.folder_open_outlined),
                  SizedBox(width: 12),
                  Expanded(child: Text('还没有找到最近项目。新建项目后，它会出现在这里。')),
                ],
              ),
            ),
          )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 1050
                  ? 3
                  : constraints.maxWidth >= 680
                  ? 2
                  : 1;
              return GridView.builder(
                itemCount: projects.length,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: 14,
                  mainAxisSpacing: 14,
                  childAspectRatio: columns == 1 ? 3.7 : 2.2,
                ),
                itemBuilder: (context, index) {
                  final project = projects[index];
                  return _RecentProjectCard(
                    project: project,
                    enabled: canOpen && !loading,
                    onOpen: () => onOpen(_projectRoot(project)),
                  );
                },
              );
            },
          ),
      ],
    );
  }
}

class _RecentProjectCard extends StatelessWidget {
  const _RecentProjectCard({
    required this.project,
    required this.enabled,
    required this.onOpen,
  });

  final Map<String, dynamic> project;
  final bool enabled;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final projectInfo = _nestedMap(project, 'project');
    final video = _nestedMap(project, 'video');
    final statistics = _nestedMap(project, 'statistics');
    final root = _projectRoot(project);
    final name = _stringValue(projectInfo['name']) ?? _pathName(root);
    final videoPath = _stringValue(video['source_path']);
    final goalCount = _intValue(statistics['goal_count']);
    final candidateCount = _intValue(statistics['candidate_count']);
    final lastModified = _formatDate(_stringValue(project['last_modified_at']));

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onOpen : null,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                child: Icon(
                  Icons.folder_special_outlined,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      videoPath == null ? root : _pathName(videoPath),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '$goalCount 个已确认 · $candidateCount 个候选${lastModified == null ? '' : ' · $lastModified'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: '打开项目',
                onPressed: enabled ? onOpen : null,
                icon: const Icon(Icons.arrow_forward),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          const Spacer(),
          Text(value, style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }
}

class _WorkflowCard extends StatelessWidget {
  const _WorkflowCard();

  @override
  Widget build(BuildContext context) {
    const steps = [
      ('01', '导入视频', Icons.file_upload_outlined),
      ('02', '框选篮筐', Icons.crop_free),
      ('03', '分析候选', Icons.track_changes),
      ('04', '人工审核', Icons.fact_check_outlined),
      ('05', '导出集锦', Icons.ios_share_outlined),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 22),
        child: Wrap(
          spacing: 18,
          runSpacing: 18,
          children: [
            for (final step in steps)
              SizedBox(
                width: 170,
                child: Row(
                  children: [
                    Icon(
                      step.$3,
                      size: 20,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          step.$1,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                        Text(
                          step.$2,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _projectRoot(Map<String, dynamic> project) {
  final root =
      project['project_root'] ?? _nestedMap(project, 'project')['root_path'];
  return root?.toString() ?? '';
}

Map<String, dynamic> _nestedMap(Map<String, dynamic> value, String key) {
  final nested = value[key];
  return nested is Map
      ? Map<String, dynamic>.from(nested)
      : <String, dynamic>{};
}

String? _stringValue(Object? value) {
  final result = value?.toString();
  return result == null || result.isEmpty ? null : result;
}

int _intValue(Object? value) => value is num ? value.toInt() : 0;

String _pathName(String path) {
  if (path.isEmpty) return '未命名项目';
  final normalized = path.replaceAll('\\', '/');
  final parts = normalized.split('/').where((part) => part.isNotEmpty).toList();
  return parts.isEmpty ? path : parts.last;
}

String? _formatDate(String? value) {
  if (value == null) return null;
  final date = DateTime.tryParse(value)?.toLocal();
  if (date == null) return null;
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  final hour = date.hour.toString().padLeft(2, '0');
  final minute = date.minute.toString().padLeft(2, '0');
  return '$month-$day $hour:$minute';
}

String _formatDuration(int milliseconds) {
  if (milliseconds <= 0) return '--:--';
  final seconds = milliseconds ~/ 1000;
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final remaining = seconds % 60;
  return hours > 0
      ? '$hours:${minutes.toString().padLeft(2, '0')}:${remaining.toString().padLeft(2, '0')}'
      : '${minutes.toString().padLeft(2, '0')}:${remaining.toString().padLeft(2, '0')}';
}
