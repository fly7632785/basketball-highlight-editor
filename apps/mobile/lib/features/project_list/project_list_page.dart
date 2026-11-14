part of '../../mobile_ui.dart';

bool _canManageProjects(BuildContext context, MobileAppState state) {
  final reason = state.projectManagementBlockReason;
  if (reason == null) return true;
  showBheToast(context, context.bheText(reason));
  return false;
}

Future<void> _createManagedProject(
  BuildContext context,
  MobileAppState state,
) async {
  if (!_canManageProjects(context, state)) return;
  await state.createNewProjectAndPickVideo(requireIdle: true);
  if (context.mounted && state.projectManagementBlockReason != null) {
    _canManageProjects(context, state);
  }
}

Future<void> _showProjectList(BuildContext context, MobileAppState state) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => _ProjectListPage(state: state)),
    );

Future<void> _confirmManagedDelete(
  BuildContext context,
  MobileAppState state,
  ProjectSnapshot project,
) async {
  final yes = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.bheText('删除项目？')),
      content: Text(
        '${project.name}\n\n${context.bheText('将删除项目及应用内视频副本、封面和导出文件；不会删除原视频或相册中的文件。')}',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(context.bheText('取消')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(context.bheText('删除项目')),
        ),
      ],
    ),
  );
  if (yes != true || !context.mounted || !_canManageProjects(context, state)) {
    return;
  }
  final ok = await state.deleteManagedProject(project.id);
  if (!ok && context.mounted) {
    if (state.projectManagementBlockReason != null) {
      _projectActionFailed(context, state);
    } else {
      showBheToast(
        context,
        context.bheText('删除未完成，部分文件可能已移除，请刷新项目列表。'),
        action: SnackBarAction(
          label: context.bheText('反馈'),
          onPressed: () =>
              showMobileDiagnostics(context, error: state.diagnosticError),
        ),
      );
    }
  }
}

void _projectActionFailed(BuildContext context, MobileAppState state) {
  final reason = state.projectManagementBlockReason;
  showBheToast(
    context,
    context.bheText(reason ?? '保存失败，请重试'),
    action: reason == null
        ? SnackBarAction(
            label: context.bheText('反馈'),
            onPressed: () =>
                showMobileDiagnostics(context, error: state.diagnosticError),
          )
        : null,
  );
}

class _ProjectListPage extends StatefulWidget {
  const _ProjectListPage({required this.state});
  final MobileAppState state;
  @override
  State<_ProjectListPage> createState() => _ProjectListPageState();
}

class _ProjectListPageState extends State<_ProjectListPage> {
  late Future<ProjectCatalog> catalog;
  @override
  void initState() {
    super.initState();
    catalog = widget.state.listSavedProjects();
  }

  void refresh() => setState(() => catalog = widget.state.listSavedProjects());

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.bheText('项目列表'))),
    body: FutureBuilder<ProjectCatalog>(
      future: catalog,
      builder: (context, snapshot) {
        if (!snapshot.hasData && !snapshot.hasError) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(context.bheText('加载项目失败')),
                TextButton(
                  onPressed: refresh,
                  child: Text(context.bheText('重试')),
                ),
                TextButton(
                  onPressed: () => showMobileDiagnostics(
                    context,
                    error: widget.state.diagnosticError,
                  ),
                  child: Text(context.bheText('反馈')),
                ),
              ],
            ),
          );
        }
        final value = snapshot.data!;
        if (value.items.isEmpty && value.errors.isEmpty) {
          return Center(child: Text(context.bheText('还没有项目')));
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (value.errors.isNotEmpty)
              TextButton(
                onPressed: () => showMobileDiagnostics(context),
                child: Text(context.bheText('部分项目读取失败，查看反馈')),
              ),
            for (final item in value.items) _row(context, item),
          ],
        );
      },
    ),
  );

  Widget _row(BuildContext context, ProjectCatalogItem item) {
    final state = widget.state, project = item.project;
    final current = project.id == state.project.id;
    final date = item.modifiedAt.toLocal();
    final dateText =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: IntrinsicHeight(
          child: Row(
            children: [
              Container(
                width: 3,
                color: current ? BhePalette.orange : Colors.transparent,
              ),
              Expanded(
                child: InkWell(
                  onTap: () async {
                    if (!_canManageProjects(context, state)) return;
                    await state.openProject(project.id, requireIdle: true);
                    if (context.mounted &&
                        state.projectManagementBlockReason != null) {
                      _canManageProjects(context, state);
                    }
                    if (context.mounted && state.project.id == project.id) {
                      Navigator.pop(context);
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: item.coverPath == null
                              ? Container(
                                  width: 56,
                                  height: 56,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.surfaceContainerHighest,
                                  child: const Icon(LucideIcons.film),
                                )
                              : Image.file(
                                  File(item.coverPath!),
                                  width: 56,
                                  height: 56,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => const SizedBox(
                                    width: 56,
                                    height: 56,
                                    child: Icon(LucideIcons.film),
                                  ),
                                ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      project.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleSmall,
                                    ),
                                  ),
                                  if (current)
                                    Padding(
                                      padding: const EdgeInsets.only(left: 4),
                                      child: Text(
                                        context.bheText('当前'),
                                        style: TextStyle(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.primary,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              Text(
                                '${context.bheText('最近修改')} $dateText\n${context.bheText('片段')} ${project.candidates.length} · ${context.bheText('保留')} ${project.includedCount} · ${context.bheText(switch (project.lastAnalysisStatus) {
                                  'completed' => '已分析',
                                  'running' => '分析中',
                                  'interrupted' => '分析中断',
                                  _ => '未分析',
                                })}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: context.bheText('更多操作'),
                onSelected: (action) async {
                  if (action == 'rename') {
                    final name = await showDialog<String>(
                      context: context,
                      builder: (_) => _ProjectRenameDialog(name: project.name),
                    );
                    if (name != null && context.mounted) {
                      if (!await state.renameManagedProject(project.id, name) &&
                          context.mounted) {
                        _projectActionFailed(context, state);
                      }
                    }
                  } else if (action == 'close') {
                    if (_canManageProjects(context, state) &&
                        !await state.closeManagedProject() &&
                        context.mounted) {
                      _projectActionFailed(context, state);
                    }
                  } else if (action == 'delete') {
                    if (_canManageProjects(context, state)) {
                      await _confirmManagedDelete(context, state, project);
                    }
                  }
                  if (mounted) refresh();
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'rename',
                    child: Text(context.bheText('重命名项目')),
                  ),
                  if (current)
                    PopupMenuItem(
                      value: 'close',
                      child: Text(context.bheText('关闭项目')),
                    ),
                  const PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(
                      context.bheText('删除项目'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
