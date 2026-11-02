import 'dart:convert';
import 'dart:io';

import 'package:bhe_core/bhe_core.dart';
import 'package:crypto/crypto.dart' as hashing;
import 'package:test/test.dart';

/// 起一个只回一份字节的本地 HTTP 服务，走真实的 HttpClient 和真实文件系统。
Future<HttpServer> _serve(List<int> bytes) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response
      ..statusCode = HttpStatus.ok
      ..contentLength = bytes.length
      ..add(bytes);
    await request.response.close();
  });
  return server;
}

void main() {
  late Directory cache;
  late HttpServer server;

  setUp(() async {
    cache = await Directory.systemTemp.createTemp('bhe-update-cache-');
  });

  tearDown(() async {
    await server.close(force: true);
    if (await cache.exists()) await cache.delete(recursive: true);
  });

  test('keeps only the package it just verified and leaves other files alone', () async {
    const version = '0.1.14';
    final bytes = utf8.encode('new package body');
    server = await _serve(bytes);
    final stale = File('${cache.path}${Platform.pathSeparator}BHE-macos-v0.1.13.dmg')
      ..writeAsBytesSync(utf8.encode('old package'));
    final stalePart = File(
      '${cache.path}${Platform.pathSeparator}BHE-macos-v0.1.14.dmg.part',
    )..writeAsBytesSync(utf8.encode('half'));
    final userFile = File('${cache.path}${Platform.pathSeparator}notes.txt')
      ..writeAsStringSync('用户自己的文件');
    final userPart = File('${cache.path}${Platform.pathSeparator}notes.part')
      ..writeAsStringSync('不是更新残片的 .part 文件');

    final file = await downloadUpdate(
      UpdatePackage(
        url: Uri.parse('http://127.0.0.1:${server.port}/BHE-macos-v$version.dmg'),
        sha256: hashing.sha256.convert(bytes).toString(),
        size: bytes.length,
        version: version,
      ),
      cache,
    );

    expect(await file.readAsBytes(), bytes);
    expect(stale.existsSync(), isFalse);
    expect(stalePart.existsSync(), isFalse);
    expect(userFile.existsSync(), isTrue);
    expect(userFile.readAsStringSync(), '用户自己的文件');
    expect(userPart.existsSync(), isTrue, reason: '只清 BHE- 开头的更新文件，不删别的 .part');
  });

  test('reports an unwritable cache instead of the raw dart exception', () async {
    const version = '0.1.14';
    final bytes = utf8.encode('new package body');
    server = await _serve(bytes);
    final readOnly = Directory('${cache.path}${Platform.pathSeparator}locked')
      ..createSync();
    // 目录不可写（macOS/Linux 上非 root 就是权限不足），模拟磁盘满/无权限。
    await Process.run('chmod', ['500', readOnly.path]);
    addTearDown(() => Process.run('chmod', ['700', readOnly.path]));

    await expectLater(
      downloadUpdate(
        UpdatePackage(
          url: Uri.parse('http://127.0.0.1:${server.port}/BHE-macos-v$version.dmg'),
          sha256: hashing.sha256.convert(bytes).toString(),
          size: bytes.length,
          version: version,
        ),
        readOnly,
      ),
      throwsA(
        isA<UpdateException>().having(
          (error) => error.message,
          'message',
          '磁盘空间不足或无法写入更新缓存，请清理空间后重试',
        ),
      ),
    );
  });
}
