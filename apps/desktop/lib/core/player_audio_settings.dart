import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_log.dart';

/// 播放器音频设置：音量 0–100 与是否静音，跨页面共用一份并记住到磁盘。
///
/// 桌面端所有播放器都从 `createLoggedPlayer` 出来，那里会把播放器登记进来，
/// 之后音量变化会同步到所有还活着的播放器（切片段、回原视频都不受影响）。
class PlayerAudioSettings extends ChangeNotifier {
  PlayerAudioSettings();
  static const volumeKey = 'bhe.player.volume';
  static const mutedKey = 'bhe.player.muted';

  static const defaultVolume = 100;

  int _volume = defaultVolume;
  bool _muted = false;
  bool _loaded = false;
  bool get loaded => _loaded;

  /// 记住的音量（静音时也保留）。
  int get volume => _volume;
  bool get muted => _muted;

  /// 实际输出音量：静音时为 0，取消静音后恢复记着的音量。
  int get effectiveVolume => _muted ? 0 : _volume;

  final Set<Player> _players = {};

  /// 额外的音量出口：测试里注入假的「设置音量」回调，避免起真 mpv。
  final Set<void Function(int volume)> _sinks = {};

  void addVolumeSink(void Function(int volume) sink) {
    _sinks.add(sink);
    sink(effectiveVolume);
  }

  void removeVolumeSink(void Function(int volume) sink) => _sinks.remove(sink);

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _volume = (prefs.getInt(volumeKey) ?? defaultVolume).clamp(0, 100);
      _muted = prefs.getBool(mutedKey) ?? false;
    } catch (error) {
      // 读失败就用默认值（满音量、不静音）。
      appLog('warn', 'player', '读取音量设置失败，用默认值: $error');
      _volume = defaultVolume;
      _muted = false;
    }
    _loaded = true;
    _applyToPlayers();
    notifyListeners();
  }

  void registerPlayer(Player player) {
    _players.add(player);
    _setPlayerVolume(player);
  }

  void unregisterPlayer(Player player) => _players.remove(player);

  void setVolume(int value) {
    final next = value.clamp(0, 100);
    if (next == _volume && !_muted) return;
    _volume = next;
    _muted = false;
    _applyToPlayers();
    unawaited(_persist());
    notifyListeners();
  }

  void setMuted(bool value) {
    if (value == _muted) return;
    _muted = value;
    _applyToPlayers();
    unawaited(_persist());
    appLog('info', 'player', value ? '已静音' : '取消静音（恢复 $_volume%）');
    notifyListeners();
  }

  void toggleMute() => setMuted(!_muted);

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(volumeKey, _volume);
      await prefs.setBool(mutedKey, _muted);
    } catch (error) {
      appLog('warn', 'player', '保存音量设置失败: $error');
    }
  }

  Future<void> reset() async {
    _players.clear();
    _sinks.clear();
    _volume = defaultVolume;
    _muted = false;
  }

  void _applyToPlayers() {
    for (final player in _players.toList()) {
      _setPlayerVolume(player);
    }
    for (final sink in _sinks.toList()) {
      sink(effectiveVolume);
    }
  }

  /// 不 await：调音量不能阻塞界面事件（Windows 上更要注意）。
  void _setPlayerVolume(Player player) {
    unawaited(
      player.setVolume(effectiveVolume.toDouble()).catchError((Object error) {
        appLog('warn', 'player', '设置音量失败: $error');
      }),
    );
  }
}

/// 全局唯一的一份（界面和 `createLoggedPlayer` 都读它）。
final playerAudioSettings = PlayerAudioSettings();