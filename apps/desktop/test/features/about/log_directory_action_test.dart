import 'dart:io';

import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:desktop/core/app_log.dart';
import 'package:desktop/features/about/log_directory_action.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'creates the log folder before passing its exact path to the system',
    () async {
      final root = Directory.systemTemp.createTempSync('bhe-log-open-');
      addTearDown(() => root.deleteSync(recursive: true));
      final path = '${root.path}/日志 folder & files';
      String? opened;
      await openLogDirectory(
        directory: path,
        opener: (directory) async {
          expect(Directory(directory).existsSync(), isTrue);
          opened = directory;
          return true;
        },
      );
      expect(opened, path);
    },
  );

  test('a rejected system open is reported as a failure', () async {
    final root = Directory.systemTemp.createTempSync('bhe-log-fail-');
    addTearDown(() => root.deleteSync(recursive: true));
    await expectLater(
      openLogDirectory(directory: root.path, opener: (_) async => false),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('directory creation errors do not launch the system opener', () async {
    final root = Directory.systemTemp.createTempSync('bhe-log-file-');
    addTearDown(() => root.deleteSync(recursive: true));
    final file = File('${root.path}/not-a-directory')
      ..writeAsStringSync('test');
    var called = false;
    await expectLater(
      openLogDirectory(
        directory: file.path,
        opener: (_) async {
          called = true;
          return true;
        },
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(called, isFalse);
  });

  for (final language in ['zh', 'en']) {
    testWidgets('failed log open offers a copyable path in $language', (
      tester,
    ) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(language),
          localizationsDelegates: BheLocalizations.localizationsDelegates,
          supportedLocales: BheLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => openLogDirectoryWithFeedback(
                  context,
                  open: () async =>
                      throw const ProcessException('open', [], 'denied'),
                ),
                child: const Text('test-open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('test-open'));
      await tester.pumpAndSettle();
      expect(
        find.text(language == 'zh' ? '无法打开日志目录' : 'Could not open log folder'),
        findsOneWidget,
      );
      final directory = engineLogDirectory(Platform.environment);
      expect(find.widgetWithText(SelectableText, directory), findsOneWidget);
      await tester.tap(find.text(language == 'zh' ? '复制路径' : 'Copy path'));
      await tester.pumpAndSettle();
      expect(copied, directory);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
