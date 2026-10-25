import 'dart:convert';
import 'dart:io';

import 'package:bhe_core/bhe_core.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

/// 本地起一个更新服务器：/latest.json、/latest.json.sig、/pkg.dmg（支持 Range）。
Future<HttpServer> _serve(Map<String, List<int>> files) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final body = files[request.uri.path];
    if (body == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final range = request.headers.value(HttpHeaders.rangeHeader);
    final start = range == null
        ? 0
        : int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
    request.response.statusCode = start > 0
        ? HttpStatus.partialContent
        : HttpStatus.ok;
    request.response.add(body.sublist(start));
    await request.response.close();
  });
  return server;
}

void main() {
  test('compares release versions and ignores build numbers', () {
    expect(isNewerVersion('0.1.11', '0.1.10'), isTrue);
    expect(isNewerVersion('0.1.10', '0.1.9'), isTrue);
    expect(isNewerVersion('0.1.10', '0.1.10+234a9d7'), isFalse);
    expect(isNewerVersion('v0.2.0', '0.1.10'), isTrue);
    expect(isNewerVersion('0.1.11', 'dev'), isFalse);
  });

  test('accepts a manifest signed by the release key with openssl', () async {
    // 用 ~/.bhe-secrets/update_signing_key.pem 经 `openssl pkeyutl -sign -rawin`
    // 签出来的样本，和发版流程的签名方式一致。
    final body = base64Decode(
      'eyJ2ZXJzaW9uIjoiMC4xLjExIiwibm90ZXMiOnsiemgiOiLmtYvor5UifSwicGFja2FnZXMiOnt9fQo=',
    );
    final signature = base64Decode(
      'JZXoVHfAAb1nnq2tncUswJ4KyRWCityFDCPQuGKhnrDq0GEjAjyp9sMnPBiLP0/IM4nFOUVdO7OmMPwJUiowCg==',
    );
    final server = await _serve({
      '/latest.json': body,
      '/latest.json.sig': signature,
    });
    addTearDown(() => server.close(force: true));
    final manifest = await fetchUpdateManifest(
      url: Uri.parse('http://127.0.0.1:${server.port}/latest.json'),
    );
    expect(manifest.version, '0.1.11');
    expect(manifest.notesFor(english: true), '测试');
  });

  test('rejects a manifest whose signature does not match', () async {
    final keyPair = await Ed25519().newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final body = utf8.encode('{"version":"9.9.9","packages":{}}');
    final signature = await Ed25519().sign(
      utf8.encode('{"version":"0.0.1","packages":{}}'),
      keyPair: keyPair,
    );
    final server = await _serve({
      '/latest.json': body,
      '/latest.json.sig': signature.bytes,
    });
    addTearDown(() => server.close(force: true));
    await expectLater(
      fetchUpdateManifest(
        url: Uri.parse('http://127.0.0.1:${server.port}/latest.json'),
        publicKey: base64Encode(publicKey.bytes),
      ),
      throwsA(
        isA<UpdateException>().having(
          (e) => e.message,
          'message',
          '更新信息签名校验失败',
        ),
      ),
    );
  });

  test('resumes a partial download and verifies the checksum', () async {
    final payload = List<int>.generate(300000, (index) => index % 251);
    final server = await _serve({
      '/BHE-macos-arm64-v0.1.11-adhoc.dmg': payload,
    });
    addTearDown(() => server.close(force: true));
    final directory = await Directory.systemTemp.createTemp('bhe-update-test');
    addTearDown(() => directory.delete(recursive: true));
    final package = UpdatePackage(
      url: Uri.parse(
        'http://127.0.0.1:${server.port}/BHE-macos-arm64-v0.1.11-adhoc.dmg',
      ),
      sha256: sha256.convert(payload).toString(),
      size: payload.length,
    );
    await File(
      '${directory.path}/BHE-macos-arm64-v0.1.11-adhoc.dmg.part',
    ).writeAsBytes(payload.sublist(0, 100000));

    final progress = <int>[];
    final file = await downloadUpdate(
      package,
      directory,
      onProgress: (received, _) => progress.add(received),
    );
    expect(await file.readAsBytes(), payload);
    expect(progress.first, greaterThan(100000));
    expect(progress.last, payload.length);

    final corrupted = UpdatePackage(
      url: package.url,
      sha256: 'a' * 64,
      size: package.size,
    );
    await file.delete();
    await expectLater(
      downloadUpdate(corrupted, directory),
      throwsA(isA<UpdateException>()),
    );
    expect(
      File(
        '${directory.path}/BHE-macos-arm64-v0.1.11-adhoc.dmg.part',
      ).existsSync(),
      isFalse,
    );
  });
}
