import 'dart:io';

const feedbackEmail = 'melody7632785@gmail.com';

String feedbackMailto({String? appVersion, bool english = false}) {
  final subject = Uri.encodeComponent(english ? 'BHE feedback' : 'BHE 反馈');
  final body = Uri.encodeComponent(
    english
        ? 'Description:\n\nSteps to reproduce:\n\nEnvironment: ${appVersion ?? 'Not provided'}\n'
        : '问题描述：\n\n复现步骤：\n\n环境信息：${appVersion ?? '未填写'}\n',
  );
  return 'mailto:$feedbackEmail?subject=$subject&body=$body';
}

Future<bool> openExternalUri(String uri) async {
  final result = switch (Platform.operatingSystem) {
    'macos' => await Process.run('open', <String>[uri]),
    'windows' => await Process.run('cmd', <String>['/c', 'start', '', uri]),
    _ => await Process.run('xdg-open', <String>[uri]),
  };
  return result.exitCode == 0;
}
