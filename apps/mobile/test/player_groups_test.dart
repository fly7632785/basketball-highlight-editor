import 'dart:convert';
import 'dart:io';

import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/mobile_app_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory documents;

  setUp(() {
    documents = Directory.systemTemp.createTempSync('bhe_groups');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => documents.path,
        );
  });

  tearDown(() => documents.deleteSync(recursive: true));

  test('player groups persist and import only the missing players', () async {
    SharedPreferences.setMockInitialValues({
      MobileAppState.playerGroupsPrefsKey: jsonEncode([
        {
          'name': '周六队',
          'players': ['科比', '罗斯'],
        },
      ]),
    });
    final state = MobileAppState(
      analysisEngine: const MobileAnalysisEngineUnavailable(),
    );
    await pumpEventQueue();
    expect(state.playerGroups.single.name, '周六队');

    state.addPlayer('罗斯');
    state.addPlayer('小夏');
    state.importPlayers(state.playerGroups.single.players);
    expect(state.project.players, ['罗斯', '小夏', '科比']);

    await state.savePlayerGroup('周六队');
    await state.savePlayerGroup('周日队');
    await state.deletePlayerGroup('周日队');
    final saved = jsonDecode(
      (await SharedPreferences.getInstance()).getString(
        MobileAppState.playerGroupsPrefsKey,
      )!,
    );
    expect(saved, [
      {
        'name': '周六队',
        'players': ['罗斯', '小夏', '科比'],
      },
    ]);
    await pumpEventQueue();
  });
}
