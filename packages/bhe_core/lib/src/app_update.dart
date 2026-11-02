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
/// 本地测试升级流程时用 --dart-define=BHE_UPDATE_PUBLIC_KEY 换成测试公钥，发版构建不设置。
const updatePublicKey = String.fromEnvironment(
  'BHE_UPDATE_PUBLIC_KEY',
  defaultValue: 'mr8tLeNqVjZ5CtVX9kxflbx0tomuQoFBT8MkFBknZ48=',
);

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
    this.version,
    this.notes,
  });

  final Uri url;
  final String sha256;
  final int size;
  final String? version;
  final Map<String, String>? notes;

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

  String versionFor(String? platform) => packages[platform]?.version ?? version;

  String notesFor({required bool english, String? platform}) {
    final selected = packages[platform]?.notes ?? notes;
    return selected[english ? 'en' : 'zh'] ?? selected['zh'] ?? '';
  }

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
            entry.key.toString(): _package(
              entry.key.toString(),
              (entry.value as Map).cast(),
              version,
            ),
      },
    );
  }

  static UpdatePackage _package(
    String platform,
    Map<String, dynamic> json,
    String manifestVersion,
  ) {
    final url = Uri.tryParse(json['url']?.toString() ?? '');
    final sha256 = json['sha256'];
    final size = json['size'];
    if (url == null || url.scheme != 'https' && url.scheme != 'http') {
      throw const UpdateException('更新信息里的下载地址无效');
    }
    if (sha256 is! String || sha256.length != 64 || size is! int || size <= 0) {
      throw const UpdateException('更新信息里的安装包校验信息无效');
    }
    final version = json['version'];
    final notes = json['notes'];
    if (version != null) {
      final parsed = version is String ? _UpdateVersion.parse(version) : null;
      final family = platform.split('-').first;
      if (parsed == null ||
          compareVersions(parsed.core, manifestVersion) != 0 ||
          (parsed.family != null && parsed.family != family)) {
        throw const UpdateException('更新信息里的版本号无效');
      }
    }
    if (notes != null &&
        (notes is! Map ||
            notes.entries.any((e) => e.key is! String || e.value is! String))) {
      throw const UpdateException('更新信息格式无效');
    }
    return UpdatePackage(
      url: url,
      sha256: sha256.toLowerCase(),
      size: size,
      version: version as String?,
      notes: notes == null ? null : (notes as Map).cast<String, String>(),
    );
  }
}

class _UpdateVersion {
  _UpdateVersion(this.core, this.numbers, this.family, this.patch);
  final String core;
  final List<int> numbers;
  final String? family;
  final int patch;

  static _UpdateVersion? parse(String value) {
    final match = RegExp(
      r'^v?([0-9]+(?:\.[0-9]+)*)(?:\+([0-9A-Za-z.-]+))?$',
    ).firstMatch(value.trim());
    if (match == null) return null;
    final core = match[1]!;
    final metadata = match[2];
    String? family;
    var patch = 0;
    if (metadata != null) {
      final reserved = RegExp(
        r'^(android|macos|windows)(?:\.|$)',
      ).hasMatch(metadata);
      final suffix = RegExp(
        r'^(android|macos|windows)\.([0-9]+)$',
      ).firstMatch(metadata);
      if (reserved && suffix == null) return null;
      if (suffix != null) {
        family = suffix[1];
        final number = int.tryParse(suffix[2]!);
        if (number == null) return null;
        patch = number;
      }
    }
    final numbers = core.split('.').map(int.tryParse).toList();
    if (numbers.contains(null)) return null;
    return _UpdateVersion(core, numbers.cast<int>(), family, patch);
  }
}

/// Numeric versions compare first; recognized platform patch numbers compare next.
/// Other build metadata remains informational. Invalid/cross-family versions return null.
int? compareVersions(String a, String b) {
  final left = _UpdateVersion.parse(a);
  final right = _UpdateVersion.parse(b);
  if (left == null ||
      right == null ||
      (left.family != null &&
          right.family != null &&
          left.family != right.family))
    return null;
  for (var i = 0; i < left.numbers.length || i < right.numbers.length; i++) {
    final diff =
        (i < left.numbers.length ? left.numbers[i] : 0) -
        (i < right.numbers.length ? right.numbers[i] : 0);
    if (diff != 0) return diff.sign;
  }
  return (left.patch - right.patch).sign;
}

/// Old Windows helpers require the full base version in bhe-release.json.
/// The signed package digest binds the exact patch; release_version records its tag.
String windowsInstallerVersion(String version) =>
    version.replaceFirst(RegExp(r'\+windows\.[0-9]+$'), '');

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
  try {
    return await _downloadUpdate(
      package,
      directory,
      onProgress: onProgress,
      client: client,
    );
  } on FileSystemException {
    // 磁盘满、缓存目录没权限、安装包被占用：不要把 Dart 异常原文抛给用户。
    throw const UpdateException('磁盘空间不足或无法写入更新缓存，请清理空间后重试');
  }
}

Future<File> _downloadUpdate(
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
  final downloaded = await partial.rename(target.path);
  await _pruneStaleDownloads(directory, keep: downloaded);
  return downloaded;
}

/// 清掉缓存目录里其它版本的安装包和下载残片，只认本应用发版时的命名规则。
///
/// 不打补丁的旧版本会一直堆在 `~/Library/Caches/BHE/updates` 这类目录里，
/// 这里是唯一自然的清理时机：新包已经校验通过，旧包不再有用。
Future<void> _pruneStaleDownloads(Directory directory, {required File keep}) async {
  final keepName = keep.uri.pathSegments.last;
  try {
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (name == keepName) continue;
      // 发版脚本产出的包都以 BHE- 开头；残片是 <包名>.part。
      if (!name.startsWith('BHE-') && !name.endsWith('.part')) continue;
      try {
        await entity.delete();
      } on FileSystemException {
        // 旧包删不掉不影响这次更新。
      }
    }
  } on FileSystemException {
    // 目录读不了就跳过清理，更新本身已经成功。
  }
}

Future<String> _sha256(File file) async =>
    (await hashing.sha256.bind(file.openRead()).first).toString();
