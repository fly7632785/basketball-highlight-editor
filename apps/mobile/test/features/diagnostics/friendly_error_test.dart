import 'dart:io';
import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:flutter/widgets.dart';
import 'package:bhe_mobile/app_updater.dart';
import 'package:bhe_mobile/features/diagnostics/friendly_error.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'disk, permissions, missing sources and update files use actionable text',
    () {
      expect(
        friendlyMobileError(
          const FileSystemException(
            'failed',
            '/private/game.mp4',
            OSError('ENOSPC', 28),
          ),
        ).message,
        '手机存储空间不足，请清理后重试。',
      );
      expect(
        friendlyMobileError(
          const FileSystemException('failed', '', OSError('EACCES', 13)),
        ).message,
        '没有读取这个文件的权限，请重新选择。',
      );
      expect(
        friendlyMobileError(
          const FileSystemException('failed', '', OSError('ENOENT', 2)),
          operation: 'video.open',
        ).message,
        '视频文件找不到了，请重新选择原视频。',
      );
      expect(
        friendlyMobileError(
          const FileSystemException('failed', '', OSError('ENOENT', 2)),
          operation: 'update.install',
        ).message,
        '更新安装包找不到了，请重新下载。',
      );
    },
  );
  test(
    'format and invalid arguments are distinct; raw errors never become UI text',
    () {
      expect(
        friendlyMobileError(
          PlatformException(
            code: 'EXPORT_FAILED',
            message: 'Failed to add track to muxer',
            details: {'mime': 'audio/apac'},
          ),
        ).message,
        '这个视频的格式（APAC）手机无法处理。',
      );
      expect(
        friendlyMobileError(
          PlatformException(code: 'VideoError', message: 'decoder failed'),
        ).message,
        '这个视频的格式手机无法处理。',
      );
      expect(
        friendlyMobileError(
          PlatformException(
            code: 'INVALID_ARGUMENT',
            message: 'bad /private/path',
          ),
        ).message,
        '设置无效，请检查视频范围后重试。',
      );
      final raw = StateError('TECHNICAL_DETAIL /private/user/game.mp4');
      final wrapped = MobileDiagnosticException(raw, 'analysis');
      expect(wrapped.cause, same(raw));
      expect(friendlyMobileError(wrapped).message, '出错了：视频分析未完成，请重试。');
      expect(
        friendlyMobileError(wrapped).message,
        isNot(contains('TECHNICAL_DETAIL')),
      );
      expect(
        friendlyMobileError(
          const SocketException('offline'),
          operation: 'update.check',
        ).message,
        '连不上更新服务器，请检查网络',
      );
    },
  );
  test('user cancellation has no error banner', () {
    expect(
      friendlyMobileError(
        PlatformException(code: 'EXPORT_CANCELLED'),
      ).cancelled,
      isTrue,
    );
    expect(
      friendlyMobileError(PlatformException(code: 'EXPORT_CANCELLED')).message,
      isNull,
    );
  });

  test(
    'share failures and photo permission denial have action-specific text',
    () {
      expect(
        friendlyMobileError(
          StateError('share transport failed'),
          operation: 'share',
        ).message,
        '无法打开分享面板，请重试。',
      );
      expect(
        friendlyMobileError(
          PlatformException(code: 'PHOTO_PERMISSION_DENIED'),
          operation: 'gallery.save',
        ).message,
        '没有相册保存权限，请在系统设置中允许 BHE 添加照片。',
      );
    },
  );
  test('new dynamic and unknown error sentences are fully localized', () async {
    final english = await BheLocalizations.delegate.load(const Locale('en'));
    expect(
      english.text('这个视频的格式（HEVC）手机无法处理。'),
      'This phone cannot process this video format (HEVC).',
    );
    expect(english.text('出错了：视频分析未完成，请重试。'), isNot(contains('出错')));
    expect(
      english.text('无法打开分享面板，请重试。'),
      "Couldn't open the share sheet. Please try again.",
    );
    expect(
      english.text('没有相册保存权限，请在系统设置中允许 BHE 添加照片。'),
      contains('permission to save to Photos'),
    );
  });

  test(
    'installation channel failures remain in diagnostics and never escape to UI',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const channel = MethodChannel('com.bhe.bhe/mobile_update');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(
          code: 'UPDATE_INSTALL_FAILED',
          message: 'ENOSPC /private/update.apk',
        ),
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final updater = AppUpdater()..file = File('/not-read/update.apk');
      addTearDown(updater.dispose);
      expect(await updater.install(), isFalse);
      expect(updater.status, UpdateStatus.failed);
      expect(updater.error, '手机存储空间不足，请清理后重试。');
      expect(updater.diagnosticError?.error, isA<PlatformException>());
    },
  );
}
