// D-L057：mpv 的「property not found _setProperty(osc, 1)」是已知无害提示，
// 要记成 debug 而不是 error（它此前还误导了「界面卡顿最后一步」）。
import 'package:desktop/core/app_diagnostics.dart';
import 'package:desktop/core/app_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('只认这一条原文，其它 mpv 报错照常算错误', () {
    expect(
      isHarmlessMpvLog('media_kit: error: property not found _setProperty(osc, 1)'),
      isTrue,
    );
    expect(isHarmlessMpvLog('[ffmpeg] error: something broke'), isFalse);
    expect(
      isHarmlessMpvLog('property not found _setProperty(osc, 1) extra'),
      isTrue,
      reason: '同一行里带前后缀也认',
    );
    expect(isHarmlessMpvLog('property not found _setProperty(volume, 50)'), isFalse);
  });

  test('写进日志时是 debug 而不是 error', () async {
    appLog('debug', 'player', '审核页 mpv media_kit: property not found _setProperty(osc, 1)');
    final file = appLogFileOverride;
    expect(file, isNotNull);
    final text = file!.existsSync() ? file.readAsStringSync() : '';
    expect(text, contains('[debug] [player]'));
    expect(
      text.contains('[error] [player] 审核页 mpv'),
      isFalse,
      reason: '这条提示不该再记成 error',
    );
  });
}
