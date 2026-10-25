import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:crypto/crypto.dart' as hashing;
import 'package:cryptography/cryptography.dart';

/// 发版时 CI 传到 OSS 的更新信息；本地测试用 --dart-define=BHE_UPDATE_URL 指向别处。
const updateManifestUrl = String.fromEnvironment(
  'BHE_UPDATE_URL',
  defaultValue:
      'https://shengshengniannian.oss-cn-beijing.aliyuncs.com/shengshengniannian/basketball-highlight-editor/releases/latest.json',
);

/// 校验 latest.json 签名的 Ed25519 公钥，私钥只在发版流程里。
const updatePublicKey = 'mr8tLeNqVjZ5CtVX9kxflbx0tomuQoFBT8MkFBknZ48=';

class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

class UpdatePackage {
  const UpdatePackage({
    required this.url,
    required this.sha256,
    required this.size,
  });

  final Uri url;
  final String sha256;
  final int size;

  String get fileName => url.pathSegments.last;
}

class UpdateManifest {
  const UpdateManifest({
    required this.version,
    required this.publishedAt,
    required this.notes,
    required this.packages,
  });

  final String version;
  final String publishedAt;
  final Map<String, String> notes;
  final Map<String, UpdatePackage> packages;

  String notesFor({required bool english}) =>
      notes[english ? 'en' : 'zh'] ?? notes['zh'] ?? '';

  factory UpdateManifest.fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    final packages = json['packages'];
    if (version is! String || compareVersions(version, version) == null) {
      throw const UpdateException('更新信息里的版本号无效');
    }
    if (packages is! Map) throw const UpdateException('更新信息缺少安装包');
    return UpdateManifest(
      version: version,
      publishedAt: json['published_at']?.toString() ?? '',
      notes: {
        for (final entry in ((json['notes'] as Map?) ?? const {}).entries)
          entry.key.toString(): entry.value.toString(),
      },
      packages: {
        for (final entry in packages.entries)
          if (entry.value is Map)
            entry.key.toString(): _package((entry.value as Map).cast()),
      },
    );
  }

  static UpdatePackage _package(Map<String, dynamic> json) {
    final url = Uri.tryParse(json['url']?.toString() ?? '');
    final sha256 = json['sha256'];
    final size = json['size'];
    if (url == null || url.scheme != 'https' && url.scheme != 'http') {
      throw const UpdateException('更新信息里的下载地址无效');
    }
    if (sha256 is! String || sha256.length != 64 || size is! int || size <= 0) {
      throw const UpdateException('更新信息里的安装包校验信息无效');
    }
    return UpdatePackage(url: url, sha256: sha256.toLowerCase(), size: size);
  }
}

/// 比较 0.1.10 这类版本号，`+构建号` 不参与比较；不是数字版本（如 dev）返回 null。
int? compareVersions(String a, String b) {
  List<int>? parts(String value) {
    final core = value.trim().replaceFirst(RegExp('^v'), '').split('+').first;
    final numbers = core.split('.').map(int.tryParse).toList();
    if (numbers.isEmpty || numbers.contains(null)) return null;
    return numbers.cast<int>();
  }

  final left = parts(a);
  final right = parts(b);
  if (left == null || right == null) return null;
  for (var i = 0; i < left.length || i < right.length; i++) {
    final diff =
        (i < left.length ? left[i] : 0) - (i < right.length ? right[i] : 0);
    if (diff != 0) return diff.sign;
  }
  return 0;
}

bool isNewerVersion(String latest, String current) =>
    (compareVersions(latest, current) ?? 0) > 0;

/// 当前设备对应 latest.json 里的安装包名；不支持自动更新的平台返回 null。
String? currentUpdatePlatform() => switch (Abi.current()) {
  Abi.macosArm64 => 'macos-arm64',
  Abi.macosX64 => 'macos-x86_64',
  Abi.windowsX64 => 'windows-x64',
  Abi.androidArm64 => 'android-arm64-v8a',
  _ => null,
};

/// 下载 latest.json 和它的签名，签名不对就拒绝。
Future<UpdateManifest> fetchUpdateManifest({
  Uri? url,
  String publicKey = updatePublicKey,
  HttpClient? client,
}) async {
  final target = url ?? Uri.parse(updateManifestUrl);
  final http =
      client ?? (HttpClient()..connectionTimeout = const Duration(seconds: 10));
  try {
    final body = await _getBytes(http, target);
    final signature = await _getBytes(
      http,
      target.replace(path: '${target.path}.sig'),
    );
    final verified = await Ed25519().verify(
      body,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(
          base64Decode(publicKey),
          type: KeyPairType.ed25519,
        ),
      ),
    );
    if (!verified) throw const UpdateException('更新信息签名校验失败');
    final decoded = jsonDecode(utf8.decode(body));
    if (decoded is! Map) throw const UpdateException('更新信息格式无效');
    return UpdateManifest.fromJson(decoded.cast());
  } on SocketException {
    throw const UpdateException('连不上更新服务器，请检查网络');
  } on HttpException {
    throw const UpdateException('连不上更新服务器，请检查网络');
  } on FormatException {
    throw const UpdateException('更新信息格式无效');
  } finally {
    if (client == null) http.close();
  }
}

Future<List<int>> _getBytes(HttpClient http, Uri url) async {
  final request = await http.getUrl(url);
  final response = await request.close().timeout(const Duration(seconds: 20));
  if (response.statusCode != HttpStatus.ok) {
    await response.drain<void>();
    throw UpdateException('获取更新信息失败（HTTP ${response.statusCode}）');
  }
  final builder = BytesBuilder(copy: false);
  await for (final chunk in response.timeout(const Duration(seconds: 20))) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

/// 下载安装包到 [directory]，中断后再调用会接着下；下载完校验 SHA-256。
/// 取消下载：对传入的 [client] 调用 `close(force: true)`。
Future<File> downloadUpdate(
  UpdatePackage package,
  Directory directory, {
  void Function(int received, int total)? onProgress,
  HttpClient? client,
}) async {
  await directory.create(recursive: true);
  final target = File(
    '${directory.path}${Platform.pathSeparator}${package.fileName}',
  );
  if (await target.exists() &&
      await target.length() == package.size &&
      await _sha256(target) == package.sha256) {
    return target;
  }
  final partial = File('${target.path}.part');
  var received = await partial.exists() ? await partial.length() : 0;
  if (received > package.size) {
    await partial.delete();
    received = 0;
  }
  final http =
      client ?? (HttpClient()..connectionTimeout = const Duration(seconds: 10));
  try {
    if (received < package.size) {
      final request = await http.getUrl(package.url);
      if (received > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$received-');
      }
      final response = await request.close();
      final FileMode mode;
      if (response.statusCode == HttpStatus.partialContent) {
        mode = FileMode.append;
      } else if (response.statusCode == HttpStatus.ok) {
        mode = FileMode.write;
        received = 0;
      } else {
        await response.drain<void>();
        throw UpdateException('下载失败（HTTP ${response.statusCode}）');
      }
      final sink = partial.openWrite(mode: mode);
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, package.size);
        }
      } finally {
        await sink.close();
      }
    }
  } on SocketException {
    throw const UpdateException('下载中断，请检查网络后继续');
  } on HttpException {
    throw const UpdateException('下载中断，请检查网络后继续');
  } finally {
    if (client == null) http.close();
  }
  if (await _sha256(partial) != package.sha256) {
    await partial.delete();
    throw const UpdateException('安装包校验失败，请重新下载');
  }
  if (await target.exists()) await target.delete();
  return partial.rename(target.path);
}

Future<String> _sha256(File file) async =>
    (await hashing.sha256.bind(file.openRead()).first).toString();
