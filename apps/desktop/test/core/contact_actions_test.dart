import 'package:flutter_test/flutter_test.dart';

import 'package:desktop/core/contact_actions.dart';

void main() {
  test('feedback mailto contains the configured recipient and template', () {
    final uri = feedbackMailto(appVersion: '1.0.0');

    expect(uri, startsWith('mailto:melody7632785@gmail.com?'));
    expect(uri, contains('BHE%20%E5%8F%8D%E9%A6%88'));
    expect(uri, contains('1.0.0'));
  });

  test('feedback mailto uses English copy when requested', () {
    final uri = feedbackMailto(appVersion: '1.0.0', english: true);

    expect(uri, contains('BHE%20feedback'));
    expect(uri, contains('Description%3A'));
    expect(uri, isNot(contains('%E9%97%AE%E9%A2%98%E6%8F%8F%E8%BF%B0')));
  });

  test('Windows opens links without cmd so the & in mailto is not a command separator', () {
    final mailto = feedbackMailto(appVersion: '1.0.0');
    expect(mailto, contains('&body='));

    final windows = externalOpenCommand(mailto, platform: 'windows');
    expect(windows.executable, 'rundll32');
    expect(windows.arguments, ['url.dll,FileProtocolHandler', mailto]);

    final https = externalOpenCommand(githubIssueUrl, platform: 'windows');
    expect(https.executable, 'rundll32');
    expect(https.arguments.last, githubIssueUrl);
  });

  test('macOS and Linux keep their own openers', () {
    expect(
      externalOpenCommand('https://x.example', platform: 'macos').executable,
      'open',
    );
    expect(
      externalOpenCommand('https://x.example', platform: 'linux').executable,
      'xdg-open',
    );
  });
}
