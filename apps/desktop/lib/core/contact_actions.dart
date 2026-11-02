import 'dart:io';

export 'package:bhe_core/bhe_core.dart'
    show feedbackEmail, feedbackMailto, githubIssueUrl;

/// 各平台打开链接的命令。Windows 不经 cmd 解析：mailto 里的 `&` 在 cmd 里是命令分隔符，
/// 用 `cmd /c start` 会把 body 之后的内容当成第二条命令、丢掉邮件正文。
({String executable, List<String> arguments}) externalOpenCommand(
  String uri, {
  required String platform,
}) => switch (platform) {
  'macos' => (executable: 'open', arguments: <String>[uri]),
  'windows' => (
    executable: 'rundll32',
    arguments: <String>['url.dll,FileProtocolHandler', uri],
  ),
  _ => (executable: 'xdg-open', arguments: <String>[uri]),
};

Future<bool> openExternalUri(String uri) async {
  final command = externalOpenCommand(uri, platform: Platform.operatingSystem);
  final result = await Process.run(command.executable, command.arguments);
  return result.exitCode == 0;
}
