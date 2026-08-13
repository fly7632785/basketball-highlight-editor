import 'package:flutter_test/flutter_test.dart';

import 'package:desktop/core/contact_actions.dart';

void main() {
  test('feedback mailto contains the configured recipient and template', () {
    final uri = feedbackMailto(appVersion: '1.0.0');

    expect(uri, startsWith('mailto:melody7632785@gmail.com?'));
    expect(uri, contains('Courtside%20%E5%8F%8D%E9%A6%88'));
    expect(uri, contains('1.0.0'));
  });
}
