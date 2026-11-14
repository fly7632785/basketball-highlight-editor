part of '../../mobile_app_state.dart';

extension MobileProjectManagement on MobileAppState {
  String? get projectManagementBlockReason =>
      _heavyTaskBlockReason(startingAnalysis: true);

  Future<bool> closeManagedProject() async {
    if (projectManagementBlockReason != null) return false;
    final currentId = project.id, session = _projectSession;
    final intent = _newProjectIntent();
    var done = false;
    _closingProjects++;
    try {
    await _withProjectTransition(intent, () async {
      await _mutations.run(() async {
        if (!_isProjectIntent(intent) ||
            projectManagementBlockReason != null ||
            project.id != currentId ||
            _projectSession != session) {
          return;
        }
        _invalidateVideoPreparation();
        project = _newProject();
        _resetTransientState();
        done = true;
        _notifyProjectManagement();
      });
    });
    } finally {
      _closingProjects--;
      _notifyProjectManagement();
    }
    return done;
  }

  Future<bool> renameManagedProject(String id, String name) async {
    final value = name.trim();
    if (value.isEmpty || value.characters.length > 40) return false;
    if (id == project.id) return renameProject(value);
    try {
      return await _mutations.run(() async {
        if (_disposed || id == project.id) return false;
        final file = await _projectFile(id);
        if (!await file.exists()) return false;
        final old = const ProjectPackageCodec().decode(
          await file.readAsString(),
          includeLocalHistory: true,
        );
        if (old.id != id) throw const FormatException('Project ID mismatch');
        final next = old.copyWith(name: value);
        await commitProjectFiles({
          file: const ProjectPackageCodec().encode(next, includeLocalHistory: true),
        });
        recentProjects = [
          for (final p in recentProjects)
            if (p.id == id) next else p,
        ];
        _notifyProjectManagement();
        return true;
      });
    } on Object catch (error, stack) {
      recordDiagnosticFailure(error, stack, operation: 'project.rename');
      _notifyProjectManagement();
      return false;
    }
  }

  Future<bool> deleteManagedProject(String id) async {
    if (projectManagementBlockReason != null) return false;
    final intent = _newProjectIntent();
    var done = false;
    try {
      await _withProjectTransition(intent, () async {
        await _mutations.run(() async {
          if (!_isProjectIntent(intent) ||
              projectManagementBlockReason != null) {
            return;
          }
          final file = await _projectFile(id);
          if (!await file.exists()) return;
          final saved = const ProjectPackageCodec().decode(
            await file.readAsString(),
          );
          if (!_isProjectIntent(intent) || projectManagementBlockReason != null) {
            return;
          }
          if (saved.id != id) {
            throw const FormatException('Project ID mismatch');
          }
          final deletingCurrent = project.id == id;
          await file.delete();
          final cover = await _coverFile(id);
          if (await cover.exists()) await cover.delete();
          for (final area in ['exports', 'package_staging', 'videos']) {
            final dir = Directory(await _projectPath(id, area: area));
            if (await dir.exists()) await dir.delete(recursive: true);
          }
          recentProjects = recentProjects.where((p) => p.id != id).toList();
          coverPaths = {...coverPaths}..remove(id);
          await _persistProjects();
          if (deletingCurrent) {
            _invalidateVideoPreparation();
            project = recentProjects.isEmpty
                ? _newProject()
                : recentProjects.first;
            _resetTransientState();
          }
          done = true;
          _notifyProjectManagement();
        });
      });
    } on Object catch (error, stack) {
      recordDiagnosticFailure(error, stack, operation: 'project.delete');
      _notifyProjectManagement();
    }
    return done;
  }
}
