import 'dart:io';

import 'package:desktop/core/app_log.dart';
import 'package:desktop/core/player_audio_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    appLogFileOverride = null;
  });

  test('默认满音量、不静音，读失败也回默认值', () async {
    final settings = PlayerAudioSettings();
    await settings.load();
    expect(settings.volume, 100);
    expect(settings.muted, isFalse);
    expect(settings.effectiveVolume, 100);
  });

  test('记住的音量与静音会读回来', () async {
    SharedPreferences.setMockInitialValues({
      PlayerAudioSettings.volumeKey: 42,
      PlayerAudioSettings.mutedKey: true,
    });
    final settings = PlayerAudioSettings();
    await settings.load();
    expect(settings.volume, 42);
    expect(settings.muted, isTrue);
    expect(settings.effectiveVolume, 0);
  });

  test('静音后实际音量为 0，取消静音恢复原音量', () async {
    final settings = PlayerAudioSettings();
    await settings.load();
    settings.setVolume(60);
    expect(settings.effectiveVolume, 60);
    settings.setMuted(true);
    expect(settings.effectiveVolume, 0);
    expect(settings.volume, 60, reason: '静音不改记住的音量');
    settings.setMuted(false);
    expect(settings.effectiveVolume, 60);
  });

  test('音量设置会写进 SharedPreferences', () async {
    final settings = PlayerAudioSettings();
    await settings.load();
    settings.setVolume(30);
    settings.setMuted(true);
    await Future<void>.delayed(Duration.zero);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(PlayerAudioSettings.volumeKey), 30);
    expect(prefs.getBool(PlayerAudioSettings.mutedKey), isTrue);
  });

  test('音量变化会同步到已登记播放器的 setVolume（不阻塞）', () async {
    final settings = PlayerAudioSettings();
    await settings.load();
    final applied = <int>[];
    // 登记时就立刻套用一次（相当于新建播放器时应用已保存的设置）。
    settings.addVolumeSink(applied.add);
    expect(applied, [100]);
    settings.setVolume(25);
    settings.setMuted(true);
    await Future<void>.delayed(Duration.zero);
    expect(applied, [100, 25, 0]);
  });

  test('日志只记最终值：静音开关各一条，音量一条', () async {
    final file = await _tempLog();
    appLogFileOverride = file;
    final settings = PlayerAudioSettings();
    await settings.load();
    settings.setVolume(50);
    settings.setMuted(true);
    settings.setMuted(false);
    await Future<void>.delayed(Duration.zero);
    final lines = await file.readAsLines();
    expect(lines.where((line) => line.contains('音量设为 50%')).length, 1);
    expect(lines.where((line) => line.contains('已静音')).length, 1);
    expect(lines.where((line) => line.contains('取消静音')).length, 1);
  });
}

Future<File> _tempLog() async {
  final dir = await Directory.systemTemp.createTemp('bhe_audio_log_');
  return File('${dir.path}/app.log');
}
