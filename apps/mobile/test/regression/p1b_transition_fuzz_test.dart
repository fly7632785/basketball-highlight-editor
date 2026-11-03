// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/features/diagnostics/mobile_diagnostics.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/mobile_video_fixture.dart';
import 'seed_count.dart';

class LogBackend implements DiagnosticBackend {
  final messages = <String>[];
  @override
  Future<void> initialize(String v, String l) async {}
  @override
  Future<void> append(String m, String? k) async {
    messages.add(m);
  }

  @override
  Future<DiagnosticSnapshot> snapshot() async =>
      DiagnosticSnapshot(lines: messages, available: true);
}

void check(bool ok, String message) {
  if (!ok) throw StateError(message);
}

Future<Map<String, String>> tree(Directory root) async {
  final out = <String, String>{};
  if (!await root.exists()) return out;
  await for (final e in root.list(recursive: true, followLinks: false)) {
    final key = e.path.substring(root.path.length);
    if (e is File) out[key] = base64Encode(await e.readAsBytes());
    if (e is Directory) out['$key/'] = 'dir';
  }
  return Map.fromEntries(
    out.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
  );
}

FilePickerResult choice(File f) => FilePickerResult([
  PlatformFile(
    name: f.uri.pathSegments.last,
    path: f.path,
    size: f.lengthSync(),
  ),
]);
ProjectSnapshot normalized(ProjectSnapshot p) =>
    const ProjectPackageCodec().decode(const ProjectPackageCodec().encode(p));
String state(MobileVideoFixture f) => jsonEncode({
  'project': normalized(f.state.project).toJson(),
  'recent': [for (final p in f.state.recentProjects) normalized(p).toJson()],
});
void noTemporary(Map<String, String> snapshot) {
  for (final key in snapshot.keys) {
    check(
      !RegExp(r'(\.next$|\.previous$|\.import_|\.backup_)').hasMatch(key),
      'temporary file remains: $key',
    );
  }
}

Future<bool> edit(MobileVideoFixture f, String operation, String token) =>
    switch (operation) {
      'review' => f.state.updateCandidateNote('goal', token),
      'rename' => f.state.renameProject(token),
      _ => f.state.addPlayer(token),
    };
bool containsEdit(ProjectSnapshot p, String op, String token) => switch (op) {
  'review' => p.candidates.any((c) => c.id == 'goal' && c.note == token),
  'rename' => p.name == token,
  _ => p.players.contains(token),
};

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'minimal older import picker must not override newer new project',
    () async {
      final f = MobileVideoFixture();
      await f.init();
      try {
        final source = await f.file('original.mp4', 'original');
        f.state.project = f.project(source.path);
        check(await f.state.renameProject('Baseline'), 'baseline');
        final incoming = await f.file(
          'old.json',
          const ProjectPackageCodec().encode(
            f.project(source.path, id: 'C').copyWith(clearVideo: true),
          ),
        );
        final entered = Completer<void>(),
            picker = Completer<FilePickerResult?>();
        f.picker.pick = () {
          entered.complete();
          return picker.future;
        };
        final old = f.state.importProject();
        await entered.future;
        await f.state.createNewProject();
        final expected = state(f), before = await tree(f.data);
        picker.complete(choice(incoming));
        await old;
        await f.state.pendingProjectWrites;
        final after = await tree(f.data);
        noTemporary(after);
        check(
          state(f) == expected && jsonEncode(after) == jsonEncode(before),
          'obsolete import changed current/recent=${state(f) != expected}, files/index=${jsonEncode(after) != jsonEncode(before)}',
        );
      } finally {
        await f.close();
      }
    },
  );

  test('minimal older open must not redirect newer delete', () async {
    final f = MobileVideoFixture();
    await f.init();
    try {
      final source = await f.file('original.mp4', 'original');
      final a = f.project(source.path),
          b = f.project(source.path, id: 'B').copyWith(clearVideo: true);
      f.state.project = a;
      f.state.recentProjects = [a, b];
      await f.file(
        'BHE Mobile/projects/B.json',
        const ProjectPackageCodec().encode(b),
      );
      check(await f.state.renameProject('Baseline'), 'baseline');
      final entered = Completer<void>(), release = Completer<void>();
      var first = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async {
              if (first) {
                first = false;
                entered.complete();
                await release.future;
              }
              return f.root.path;
            },
          );
      final old = f.state.openProject('B');
      await entered.future;
      final latest = f.state.clearProject();
      release.complete();
      await old;
      await latest;
      await f.state.pendingProjectWrites;
      final aExists = await File('${f.data.path}/projects/A.json').exists(),
          bExists = await File('${f.data.path}/projects/B.json').exists();
      check(
        !aExists && bExists,
        'latest delete targeted wrong project: A_exists=$aExists B_exists=$bExists',
      );
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => f.root.path,
          );
      await f.close();
    }
  });

  test('minimal older new-video picker must not override newer import', () async {
    final f = MobileVideoFixture();
    await f.init();
    try {
      final source = await f.file('original.mp4', 'original');
      f.state.project = f.project(source.path);
      check(await f.state.renameProject('Baseline'), 'baseline');
      final incoming = await f.file(
        'new.json',
        const ProjectPackageCodec().encode(
          f
              .project(source.path, id: 'C')
              .copyWith(clearVideo: true, name: 'NewImport'),
        ),
      );
      final entered = Completer<void>(),
          picker = Completer<FilePickerResult?>();
      f.picker.pick = () {
        entered.complete();
        return picker.future;
      };
      final old = f.state.createNewProjectAndPickVideo();
      await entered.future;
      f.choose(incoming);
      await f.state.importProject();
      final expected = state(f), before = await tree(f.data);
      picker.complete(choice(source));
      await old;
      await f.state.pendingProjectWrites;
      final after = await tree(f.data);
      noTemporary(after);
      check(
        state(f) == expected && jsonEncode(after) == jsonEncode(before),
        'obsolete new-video intent changed current/recent=${state(f) != expected}, files/index=${jsonEncode(after) != jsonEncode(before)}',
      );
    } finally {
      await f.close();
    }
  });

  test(
    'minimal old import must not commit over a newer import',
    () async {
      final f = MobileVideoFixture();
      await f.init();
      try {
        final source = await f.file('original.mp4', 'original');
        f.state.project = f.project(source.path);
        check(await f.state.renameProject('Baseline'), 'baseline');
        final incoming = await f.file(
          'old.json',
          const ProjectPackageCodec().encode(
            f.project(source.path, id: 'D').copyWith(clearVideo: true),
          ),
        );
        final laterFile = await f.file(
          'new.json',
          const ProjectPackageCodec().encode(
            f.project(source.path, id: 'C').copyWith(clearVideo: true),
          ),
        );
        // 选择窗口互斥：旧窗口必须结束后新窗口才会打开。
        final firstEntered = Completer<void>(),
            first = Completer<FilePickerResult?>();
        f.picker.pick = () {
          firstEntered.complete();
          return first.future;
        };
        final old = f.state.importProject();
        await firstEntered.future;
        expect(f.state.pickerBusy, isTrue);
        first.complete(choice(incoming));
        await old;
        await f.state.pendingProjectWrites;
        expect(f.state.pickerBusy, isFalse);

        final secondEntered = Completer<void>(),
            second = Completer<FilePickerResult?>();
        f.picker.pick = () {
          secondEntered.complete();
          return second.future;
        };
        final latest = f.state.importProject();
        await secondEntered.future;
        second.complete(choice(laterFile));
        await latest;
        await f.state.pendingProjectWrites;
        check(f.state.project.id == 'C', 'newer import did not win');
        check(!f.state.pickerBusy, 'picker stayed busy after newer import');
      } finally {
        await f.close();
      }
    },
  );

  test(
    'seeded overlapping transition preparation',
    () async {
      final start =
          int.tryParse(Platform.environment['BHE_TRANSITION_SEED'] ?? '') ??
          20000;
      final count = regressionSeedCount('BHE_TRANSITION_COUNT');
      final results = <Map<String, Object?>>[],
          coverage = <String, int>{},
          outcomes = <String, int>{},
          editResults = <String, int>{},
          orders = <String, int>{};
      for (var seed = start; seed < start + count; seed++) {
        final rng = Random(seed), f = MobileVideoFixture();
        final older = ['import', 'newpick', 'open'][rng.nextInt(3)],
            later = ['new', 'open', 'delete', 'import'][rng.nextInt(4)];
        final oldOutcome = older == 'open'
            ? (['success', 'failure'][rng.nextInt(2)])
            : (['success', 'cancel', 'failure'][rng.nextInt(3)]);
        final lateOutcome = later == 'import'
            ? (['success', 'cancel', 'failure'][rng.nextInt(3)])
            : 'success';
        final beforeEdit = ['none', 'review', 'rename', 'add'][rng.nextInt(4)],
            afterEdit = ['none', 'review', 'rename', 'add'][rng.nextInt(4)];
        final delay = rng.nextInt(3),
            earlyOld = later == 'import' && older != 'open' && rng.nextBool(),
            caseKey = '$older/$later/$oldOutcome/$lateOutcome';
        coverage['$older/$later'] = (coverage['$older/$later'] ?? 0) + 1;
        final order = older == 'open'
            ? 'open-queue'
            : earlyOld
            ? 'old-picker-first'
            : 'newer-first';
        orders[order] = (orders[order] ?? 0) + 1;
        outcomes['old/$older/$oldOutcome'] =
            (outcomes['old/$older/$oldOutcome'] ?? 0) + 1;
        outcomes['later/$later/$lateOutcome'] =
            (outcomes['later/$later/$lateOutcome'] ?? 0) + 1;
        var initialized = false;
        final backend = LogBackend(),
            previousDiagnostics = MobileDiagnostics.instance;
        MobileDiagnostics.instance = MobileDiagnostics(backend);
        Completer<void>? releaseOpen;
        Completer<FilePickerResult?>? oldPicker;
        Completer<FilePickerResult?>? latePicker;
        final scenario = {
          'seed': seed,
          'older': older,
          'later': later,
          'old_outcome': oldOutcome,
          'later_outcome': lateOutcome,
          'before_edit': beforeEdit,
          'after_edit': afterEdit,
          'delay_ms': delay,
          'old_returns_first': earlyOld,
        };
        try {
          await f.init();
          initialized = true;
          final source = await f.file('original.mp4', 'original');
          final a = f.project(source.path),
              b = f.project(source.path, id: 'B').copyWith(clearVideo: true);
          f.state.project = a;
          f.state.recentProjects = [a, b];
          await f.file(
            'BHE Mobile/projects/B.json',
            const ProjectPackageCodec().encode(b),
          );
          check(await f.state.renameProject('Baseline'), 'baseline save');
          final oldFile = await f.file(
            'old.json',
            const ProjectPackageCodec().encode(
              f
                  .project(source.path, id: 'D')
                  .copyWith(clearVideo: true, name: 'OldImport'),
            ),
          );
          final newFile = await f.file(
            'new.json',
            const ProjectPackageCodec().encode(
              f
                  .project(source.path, id: 'C')
                  .copyWith(clearVideo: true, name: 'NewImport'),
            ),
          );
          final entered = Completer<void>();
          Future<void> old;
          if (older == 'open') {
            releaseOpen = Completer<void>();
            var first = true;
            final gate = releaseOpen;
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(
                  const MethodChannel('plugins.flutter.io/path_provider'),
                  (_) async {
                    if (first) {
                      first = false;
                      entered.complete();
                      await gate.future;
                      if (oldOutcome == 'failure') {
                        throw PlatformException(code: 'old_open_failure');
                      }
                    }
                    return f.root.path;
                  },
                );
            old = f.state.openProject('B');
          } else {
            oldPicker = Completer<FilePickerResult?>();
            final gate = oldPicker;
            f.picker.pick = () {
              entered.complete();
              return gate.future;
            };
            old = older == 'import'
                ? f.state.importProject()
                : f.state.createNewProjectAndPickVideo();
          }
          // Attach an error handler immediately so intentionally failing picker/open is observed.
          final oldObserved = old.then<String>(
            (_) => 'completed',
            onError: (Object e, StackTrace st) => 'error:$e',
          );
          await entered.future.timeout(const Duration(seconds: 5));
          if (beforeEdit != 'none') {
            final token = 'before_$seed', original = state(f);
            final accepted = await edit(
              f,
              beforeEdit,
              token,
            ).timeout(const Duration(seconds: 3));
            editResults['before/$beforeEdit/$accepted'] =
                (editResults['before/$beforeEdit/$accepted'] ?? 0) + 1;
            if (accepted) {
              check(
                containsEdit(f.state.project, beforeEdit, token),
                'successful prior edit silently lost',
              );
              final disk = const ProjectPackageCodec().decode(
                await File(
                  '${f.data.path}/projects/${f.state.project.id}.json',
                ).readAsString(),
              );
              check(
                containsEdit(disk, beforeEdit, token),
                'successful prior edit not persisted',
              );
            } else {
              check(state(f) == original, 'rejected prior edit changed state');
            }
          }
          if (later == 'import') {
            latePicker = Completer<FilePickerResult?>();
            final gate = latePicker;
            f.picker.pick = () => gate.future;
          }
          final beforeA = await File(
            '${f.data.path}/projects/A.json',
          ).readAsBytes();
          final beforeB = await File(
            '${f.data.path}/projects/B.json',
          ).readAsBytes();
          // 选择窗口互斥：占用中再点导入会被忽略，所以两者重叠时先把旧窗口放行。
          var oldReleased = false;
          if (later == 'import' && older != 'open') {
            oldReleased = true;
            if (oldOutcome == 'success') {
              oldPicker!.complete(choice(older == 'import' ? oldFile : source));
            }
            if (oldOutcome == 'cancel') oldPicker!.complete(null);
            if (oldOutcome == 'failure') {
              oldPicker!.completeError(
                PlatformException(code: 'old_picker_failure'),
              );
            }
            await oldObserved.timeout(const Duration(seconds: 10));
            await f.state.pendingProjectWrites;
          }
          // 新动作开始前的项目 id：失败/取消的新导入不该改变它。
          final lateStartId = f.state.project.id;
          Future<void> latest = switch (later) {
            'new' => f.state.createNewProject(),
            'open' => f.state.openProject(older == 'open' ? 'A' : 'B'),
            'delete' => f.state.clearProject(),
            _ => f.state.importProject(),
          };
          final latestObserved = latest.then<String>(
            (_) => 'completed',
            onError: (Object e, StackTrace st) => 'error:$e',
          );
          await Future<void>.delayed(Duration(milliseconds: delay));
          String? expectedState;
          Map<String, String>? expectedTree;
          String? earlyError;
          if (earlyOld && !oldReleased) {
            final beforeState = state(f), beforeTree = await tree(f.data);
            final errorCountBefore = backend.messages
                .where((m) => m.startsWith('app error:'))
                .length;
            if (oldOutcome == 'success') {
              oldPicker!.complete(choice(older == 'import' ? oldFile : source));
            }
            if (oldOutcome == 'cancel') oldPicker!.complete(null);
            if (oldOutcome == 'failure') {
              oldPicker!.completeError(
                PlatformException(code: 'old_picker_failure'),
              );
            }
            final resultOld = await oldObserved.timeout(
              const Duration(seconds: 10),
            );
            await f.state.pendingProjectWrites;
            if (resultOld != 'completed') {
              earlyError = 'old picker error escaped handling';
            }
            if (oldOutcome == 'failure' &&
                backend.messages
                        .where((m) => m.startsWith('app error:'))
                        .length <=
                    errorCountBefore) {
              earlyError = 'old picker failure not recorded';
            }
            if (state(f) != beforeState) {
              earlyError =
                  'obsolete $older changed state while newer picker pending';
            }
            if (jsonEncode(await tree(f.data)) != jsonEncode(beforeTree)) {
              earlyError =
                  'obsolete $older changed files while newer picker pending';
            }
          }
          if (later == 'import') {
            if (lateOutcome == 'success') latePicker!.complete(choice(newFile));
            if (lateOutcome == 'cancel') latePicker!.complete(null);
            if (lateOutcome == 'failure') {
              latePicker!.completeError(
                PlatformException(code: 'new_picker_failure'),
              );
            }
          }
          if (older != 'open') {
            final result = await latestObserved.timeout(
              const Duration(seconds: 5),
            );
            check(
              result == 'completed',
              'newer picker error escaped handling: $result',
            );
            if (lateOutcome == 'failure') {
              check(
                backend.messages.any(
                  (m) => m.contains('app error: project.import'),
                ),
                'newer picker failure not recorded',
              );
            }
            if (later == 'new') {
              check(
                f.state.project.id != 'A' && f.state.project.video == null,
                'newer new did not win',
              );
            }
            if (later == 'open') {
              check(f.state.project.id == 'B', 'newer open did not win');
            }
            if (later == 'delete') {
              check(
                f.state.project.id == 'B' &&
                    !await File('${f.data.path}/projects/A.json').exists(),
                'newer delete did not remove A',
              );
            }
            if (later == 'import' && lateOutcome == 'success') {
              check(f.state.project.id == 'C', 'newer import did not win');
            }
            if (later == 'import' && lateOutcome != 'success') {
              check(
                f.state.project.id == lateStartId,
                'cancelled/failed newer import changed project',
              );
            }
            if (afterEdit != 'none') {
              final token = 'after_$seed', original = state(f);
              final accepted = await edit(
                f,
                afterEdit,
                token,
              ).timeout(const Duration(seconds: 3));
              editResults['after/$afterEdit/$accepted'] =
                  (editResults['after/$afterEdit/$accepted'] ?? 0) + 1;
              if (accepted) {
                check(
                  containsEdit(f.state.project, afterEdit, token),
                  'successful later edit silently lost',
                );
                final disk = const ProjectPackageCodec().decode(
                  await File(
                    '${f.data.path}/projects/${f.state.project.id}.json',
                  ).readAsString(),
                );
                check(
                  containsEdit(disk, afterEdit, token),
                  'successful later edit not persisted',
                );
              } else {
                check(
                  state(f) == original,
                  'rejected later edit changed state',
                );
              }
            }
            await f.state.pendingProjectWrites;
            expectedState = state(f);
            expectedTree = await tree(f.data);
            noTemporary(expectedTree);
            if (!earlyOld && !oldReleased) {
              final errorCountBefore = backend.messages
                  .where((m) => m.startsWith('app error:'))
                  .length;
              if (oldOutcome == 'success') {
                oldPicker!.complete(
                  choice(older == 'import' ? oldFile : source),
                );
              }
              if (oldOutcome == 'cancel') oldPicker!.complete(null);
              if (oldOutcome == 'failure') {
                oldPicker!.completeError(
                  PlatformException(code: 'old_picker_failure'),
                );
              }
              final resultOld = await oldObserved.timeout(
                const Duration(seconds: 10),
              );
              await f.state.pendingProjectWrites;
              check(
                resultOld == 'completed',
                'old picker error escaped handling',
              );
              if (oldOutcome == 'failure') {
                check(
                  backend.messages
                          .where((m) => m.startsWith('app error:'))
                          .length >
                      errorCountBefore,
                  'old picker failure not recorded',
                );
              }
              final after = await tree(f.data);
              noTemporary(after);
              check(
                state(f) == expectedState &&
                    jsonEncode(after) == jsonEncode(expectedTree),
                'obsolete $older changed latest $later state=${state(f) != expectedState}, files/index=${jsonEncode(after) != jsonEncode(expectedTree)}',
              );
            }
            if (earlyError != null) throw StateError(earlyError);
          } else {
            if (afterEdit != 'none') {
              final original = state(f), token = 'after_$seed';
              final accepted = await edit(
                f,
                afterEdit,
                token,
              ).timeout(const Duration(seconds: 3));
              editResults['after/$afterEdit/$accepted'] =
                  (editResults['after/$afterEdit/$accepted'] ?? 0) + 1;
              check(
                !accepted && state(f) == original,
                'late edit while open transition unexpectedly accepted',
              );
            }
            // Open is paused in the serialized queue; later transitions cannot finish until it is released.
            final openErrorsBefore = backend.messages
                .where((m) => m.contains('app error: project.open'))
                .length;
            releaseOpen!.complete();
            final resultOld = await oldObserved.timeout(
              const Duration(seconds: 10),
            );
            final result = await latestObserved.timeout(
              const Duration(seconds: 10),
            );
            check(resultOld == 'completed', 'old open error escaped handling');
            if (oldOutcome == 'failure') {
              check(
                backend.messages
                        .where((m) => m.contains('app error: project.open'))
                        .length >
                    openErrorsBefore,
                'old open failure not recorded',
              );
            }
            check(result == 'completed', 'newer picker error escaped handling');
            if (lateOutcome == 'failure') {
              check(
                backend.messages.any(
                  (m) => m.contains('app error: project.import'),
                ),
                'newer picker failure not recorded',
              );
            }
            await f.state.pendingProjectWrites;
            final index =
                jsonDecode(
                      await File(
                        '${f.data.path}/project_index.json',
                      ).readAsString(),
                    )
                    as List;
            if (later != 'delete' && later != 'open') {
              check(
                base64Encode(
                      await File(
                        '${f.data.path}/projects/A.json',
                      ).readAsBytes(),
                    ) ==
                    base64Encode(beforeA),
                'obsolete open changed A file',
              );
            }
            if (later != 'delete') {
              check(
                base64Encode(
                      await File(
                        '${f.data.path}/projects/B.json',
                      ).readAsBytes(),
                    ) ==
                    base64Encode(beforeB),
                'obsolete open changed B file',
              );
            }
            if (later == 'new') {
              check(
                f.state.project.id != 'A' && f.state.project.id != 'B',
                'newer new did not win',
              );
              check(
                index.join(',') == 'A,B',
                'obsolete open changed index before new',
              );
            }
            if (later == 'open') {
              check(
                f.state.project.id == 'A' && index.join(',') == 'A,B',
                'newer open did not win',
              );
            }
            if (later == 'delete') {
              final aExists = await File(
                    '${f.data.path}/projects/A.json',
                  ).exists(),
                  bExists = await File(
                    '${f.data.path}/projects/B.json',
                  ).exists();
              check(
                !aExists && bExists,
                'obsolete open caused deletion of wrong project A_exists=$aExists B_exists=$bExists',
              );
              check(
                base64Encode(
                      await File(
                        '${f.data.path}/projects/B.json',
                      ).readAsBytes(),
                    ) ==
                    base64Encode(beforeB),
                'newer delete changed B file',
              );
            }
            if (later == 'import' && lateOutcome == 'success') {
              check(
                f.state.project.id == 'C' && index.join(',') == 'C,A,B',
                'obsolete open changed import index',
              );
            }
            if (later == 'import' && lateOutcome != 'success') {
              check(
                f.state.project.id == 'A' && index.join(',') == 'A,B',
                'obsolete open changed state after canceled new import',
              );
            }
          }
          noTemporary(await tree(f.data));
        } catch (error, stack) {
          final currentTree = initialized
              ? await tree(f.data)
              : <String, String>{};
          final temporary = currentTree.keys
              .where(
                (key) => RegExp(
                  r'(\.next$|\.previous$|\.import_|\.backup_)',
                ).hasMatch(key),
              )
              .toList();
          results.add({
            'seed': seed,
            'scenario': scenario,
            'error': '$error',
            'stack': '$stack',
            'case_key': caseKey,
            'temporary_files': temporary,
          });
        } finally {
          if (releaseOpen != null && !releaseOpen.isCompleted) {
            releaseOpen.complete();
          }
          if (oldPicker != null && !oldPicker.isCompleted) {
            oldPicker.complete(null);
          }
          if (latePicker != null && !latePicker.isCompleted) {
            latePicker.complete(null);
          }
          if (initialized) {
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(
                  const MethodChannel('plugins.flutter.io/path_provider'),
                  (_) async => f.root.path,
                );
            await f.close();
          }
          MobileDiagnostics.instance = previousDiagnostics;
        }
      }
      final result = {
        'base': 'current checkout',
        'seed_start': start,
        'sequences': count,
        'coverage': coverage,
        'return_orders': orders,
        'picker_outcomes': outcomes,
        'edit_results': editResults,
        'failure_count': results.length,
        'failures': results,
      };
      final out = Platform.environment['BHE_TRANSITION_RESULT'];
      if (out != null) {
        await File(
          out,
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(result));
      }
      print(
        'TRANSITION_SUMMARY ${jsonEncode({'sequences': count, 'coverage': coverage, 'return_orders': orders, 'picker_outcomes': outcomes, 'edit_results': editResults, 'failures': results.length})}',
      );
      if (results.isNotEmpty) {
        print(
          'FAILING_SEEDS ${results.map((failure) => failure['seed']).join(',')}\nFIRST_FAILURE ${jsonEncode(results.first)}',
        );
      }
      expect(
        results,
        isEmpty,
        reason:
            'See BHE_TRANSITION_RESULT for deterministic seeds and case details',
      );
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
