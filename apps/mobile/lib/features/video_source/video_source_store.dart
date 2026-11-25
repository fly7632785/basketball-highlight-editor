import 'dart:io';

import 'package:path/path.dart' as p;

import 'project_paths.dart';
import '../diagnostics/mobile_diagnostics.dart';

class VideoSourceCancelled implements Exception {
  const VideoSourceCancelled();
}

class VideoSourceMismatch implements Exception {
  const VideoSourceMismatch();
}

/// Injectable filesystem boundary; tests fail individual steps without filling a disk.
class VideoFileOperations {
  const VideoFileOperations();
  Future<void> copy(File from, File to, {bool Function()? isCurrent}) async {
    final input = await from.open();
    RandomAccessFile? output;
    try {
      output = await to.open(mode: FileMode.write);
      while (true) {
        if (isCurrent != null && !isCurrent()) {
          throw const VideoSourceCancelled();
        }
        final chunk = await input.read(1024 * 1024);
        if (chunk.isEmpty) break;
        await output.writeFrom(chunk);
      }
    } finally {
      try {
        await output?.close();
      } finally {
        await input.close();
      }
    }
  }

  Future<void> move(File from, File to) async => from.rename(to.path);
  Future<void> delete(File file) async {
    if (await file.exists()) await file.delete();
  }
}

class VideoSourceStore {
  VideoSourceStore({
    required this.dataDirectory,
    required this.temporaryDirectory,
    this.files = const VideoFileOperations(),
  });

  final Future<Directory> Function() dataDirectory;
  final Future<Directory> Function() temporaryDirectory;
  final VideoFileOperations files;
  final _active = <String>{};
  int _serial = 0;

  /// Only stale picker copies with no saved or in-memory project reference.
  /// Never follow symlinks or clear the entire picker cache through its plugin.
  Future<void> cleanUnusedPickerCache(Set<String> referencedPaths) async {
    final temporary = await temporaryDirectory();
    final cache = Directory(p.join(temporary.path, 'file_picker'));
    if (await FileSystemEntity.type(cache.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return;
    }
    final protected = <String>{};
    for (final path in referencedPaths) {
      protected.add(p.normalize(p.absolute(path)));
      if (await File(path).exists()) {
        protected.add(await File(path).resolveSymbolicLinks());
      }
    }
    final cutoff = DateTime.now().subtract(const Duration(days: 1));
    await for (final entry in cache.list(recursive: true, followLinks: false)) {
      if (entry is! File) continue;
      final parent = p.dirname(entry.path);
      final ownedCopy =
          parent == cache.path &&
          p.basename(entry.path).startsWith('bhe-import-');
      final legacyVideo =
          p.dirname(parent) == cache.path &&
          RegExp(r'^\d+$').hasMatch(p.basename(parent)) &&
          const {
            '.mp4',
            '.mov',
            '.m4v',
            '.mkv',
            '.webm',
            '.avi',
            '.3gp',
            '.ts',
          }.contains(p.extension(entry.path).toLowerCase());
      if (!ownedCopy && !legacyVideo) continue;
      final stat = await entry.stat();
      if (!stat.modified.isBefore(cutoff) ||
          (ownedCopy && !stat.changed.isBefore(cutoff))) {
        continue;
      }
      if (protected.contains(p.normalize(entry.absolute.path)) ||
          protected.contains(await entry.resolveSymbolicLinks())) {
        continue;
      }
      await files.delete(entry);
    }
  }

  Future<String?> existingVideo(String projectId) async {
    final directory = Directory(
      await projectStoragePath(
        await dataDirectory(),
        projectId,
        area: 'videos',
      ),
    );
    if (!await directory.exists()) return null;
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is File &&
          RegExp(
            r'^source\.[a-z0-9]{1,10}$',
          ).hasMatch(p.basename(entry.path))) {
        return entry.path;
      }
    }
    return null;
  }

  Future<bool> _movableCache(File source, bool fromPicker) async {
    if (!fromPicker) {
      return false; // Package path hints are never move authority.
    }
    final temporary = await temporaryDirectory();
    final cache = p.join(await temporary.resolveSymbolicLinks(), 'file_picker');
    return p.isWithin(
          p.join(p.normalize(temporary.absolute.path), 'file_picker'),
          p.normalize(source.absolute.path),
        ) &&
        p.isWithin(cache, await source.resolveSymbolicLinks());
  }

  /// Validate a unique staged file, install it, then persist its project record.
  /// The previous file remains recoverable until persist succeeds.
  Future<T> save<T>({
    required String sourcePath,
    required String projectId,
    required Future<T> Function(File file) validate,
    required Future<void> Function(String path, T value) persist,
    required bool Function() isCurrent,
    String? previousPath,
    bool fromPicker = false,
    Future<void> Function(Future<void> Function())? commit,
  }) async {
    if (!_active.add(projectId)) throw const VideoSourceCancelled();
    File? staging;
    File? backup;
    File? target;
    final source = File(sourcePath);
    var movedSource = false;
    var installed = false;
    var committed = false;
    void check() {
      if (!isCurrent()) throw const VideoSourceCancelled();
    }

    try {
      final directory = Directory(
        await projectStoragePath(
          await dataDirectory(),
          projectId,
          area: 'videos',
        ),
      );
      await directory.create(recursive: true);
      check();
      var extension = p.extension(sourcePath).toLowerCase();
      if (!RegExp(r'^\.[a-z0-9]{1,10}$').hasMatch(extension)) {
        extension = '.mp4';
      }
      target = File(p.join(directory.path, 'source$extension'));
      if (await FileSystemEntity.type(target.path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const FileSystemException(
          'A video target cannot be a symbolic link',
        );
      }
      if (await source.exists() &&
          await source.resolveSymbolicLinks() == target.path) {
        final value = await validate(source);
        check();
        await (commit ?? (action) => action())(() async {
          check();
          await persist(target!.path, value);
        });
        return value;
      }
      final token = '${DateTime.now().microsecondsSinceEpoch}_${_serial++}';
      staging = File(p.join(directory.path, '.import_$token$extension'));
      backup = File(p.join(directory.path, '.backup_$token$extension'));
      if (await _movableCache(source, fromPicker)) {
        try {
          await files.move(source, staging);
          movedSource = true;
        } on FileSystemException {
          await files.copy(source, staging, isCurrent: isCurrent);
        }
      } else {
        await files.copy(source, staging, isCurrent: isCurrent);
      }
      check();
      final value = await validate(staging);
      check();
      await (commit ?? (action) => action())(() async {
        if (await target!.exists()) await files.move(target, backup!);
        try {
          check();
          await files.move(staging!, target);
          installed = true;
          check();
          await persist(target.path, value);
          committed = true;
        } on Object catch (error, stack) {
          try {
            if (installed) await files.move(target, staging!);
            if (await backup!.exists()) await files.move(backup, target);
          } on Object catch (restoreError, restoreStack) {
            MobileDiagnostics.instance.error(
              restoreError,
              restoreStack,
              operation: 'video.restore',
            );
          }
          Error.throwWithStackTrace(error, stack);
        }
      });
      // Only our backup and the exact old owned source may be retired. Never
      // enumerate and recursively delete a project's other files.
      String? oldPath;
      if (previousPath != null && await File(previousPath).exists()) {
        oldPath = await File(previousPath).resolveSymbolicLinks();
      }
      for (final file in [
        backup,
        if (oldPath != null &&
            oldPath != target.path &&
            p.dirname(oldPath) == directory.path &&
            RegExp(r'^source\.[a-z0-9]{1,10}$').hasMatch(p.basename(oldPath)))
          File(oldPath),
      ]) {
        try {
          await files.delete(file);
        } on FileSystemException {
          /* Keep recoverable residue. */
        }
      }
      return value;
    } finally {
      try {
        if (!committed &&
            movedSource &&
            staging != null &&
            await staging.exists() &&
            !await source.exists()) {
          await source.parent.create(recursive: true);
          await files.move(staging, source);
        }
        if (staging != null) await files.delete(staging);
      } finally {
        _active.remove(projectId);
      }
    }
  }
}
