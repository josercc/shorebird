// flutterpatch: ownership=OURS — from meta_ota
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'ignore_rules.dart';

/// One Flutter asset file belonging to an app or a dependency package.
class ScannedAsset {
  ScannedAsset({
    required this.package,
    required this.packageHash,
    required this.path,
    required this.size,
    required this.hash,
  });

  /// Package name from pubspec / package_config.
  final String package;

  /// Hosted package content hash from `pubspec.lock` (sha256), if any.
  final String? packageHash;

  /// Path relative to the package root (Flutter asset path).
  final String path;

  /// File size in bytes.
  final int size;

  /// SHA-256 of file contents.
  final String hash;

  Map<String, dynamic> toJson() => {
        'package': package,
        'package_hash': packageHash,
        'path': path,
        'size': size,
        'hash': hash,
      };
}

class ScanAssetsResult {
  ScanAssetsResult({
    required this.appDir,
    required this.resources,
    required this.outPath,
    this.releaseVersion,
  });

  final String appDir;
  final List<ScannedAsset> resources;
  final String outPath;
  final String? releaseVersion;

  Map<String, dynamic> toJson() => {
        'app_dir': appDir,
        if (releaseVersion != null && releaseVersion!.isNotEmpty)
          'release_version': releaseVersion,
        'generated_at': DateTime.now().toUtc().toIso8601String(),
        'count': resources.length,
        'resources': resources.map((r) => r.toJson()).toList(),
      };
}

/// Scan [appDir] Flutter assets (app + dependency packages) and write JSON.
Future<ScanAssetsResult> scanFlutterAssets({
  required String appDir,
  String? outPath,
  bool includeDev = false,
  String? releaseVersion,
  bool writeConfig = true,
  FlutterPatchIgnore? ignore,
}) async {
  final root = p.normalize(p.absolute(appDir));
  final pubspecFile = File(p.join(root, 'pubspec.yaml'));
  if (!pubspecFile.existsSync()) {
    throw StateError('不是 Flutter/Dart 工程：缺少 pubspec.yaml ($root)');
  }

  final packageConfigFile = File(p.join(root, '.dart_tool', 'package_config.json'));
  if (!packageConfigFile.existsSync()) {
    throw StateError(
      '缺少 .dart_tool/package_config.json，请先在工程目录执行: flutter pub get',
    );
  }

  final ignoreRules = ignore ?? FlutterPatchIgnore.load(root);
  final lockHashes = _loadPackageHashes(File(p.join(root, 'pubspec.lock')));
  final lockKinds = _loadPackageDependencyKinds(File(p.join(root, 'pubspec.lock')));
  final packages = _loadPackages(packageConfigFile);

  final rootPubspec = loadYaml(pubspecFile.readAsStringSync());
  final rootName = rootPubspec is YamlMap
      ? (rootPubspec['name'] as String? ?? p.basename(root))
      : p.basename(root);

  // Ensure root package is included even if package_config rootUri is odd.
  packages.putIfAbsent(
    rootName,
    () => _PackageRef(name: rootName, rootUri: root),
  );

  final seen = <String>{};
  final resources = <ScannedAsset>[];

  for (final pkg in packages.values) {
    if (!_shouldIncludePackage(
      name: pkg.name,
      rootName: rootName,
      includeDev: includeDev,
      lockKinds: lockKinds,
    )) {
      continue;
    }

    final pubspecPath = p.join(pkg.rootUri, 'pubspec.yaml');
    final pubspec = File(pubspecPath);
    if (!pubspec.existsSync()) continue;

    final assetPaths = assetPathsFromPubspec(pubspec.readAsStringSync());
    final packageHash = lockHashes[pkg.name];
    final isRoot = pkg.name == rootName;

    for (final relative in assetPaths) {
      for (final fileRel in expandAssetEntry(pkg.rootUri, relative)) {
        final abs = p.normalize(p.join(pkg.rootUri, fileRel));
        final posixRel = fileRel.replaceAll('\\', '/');
        final snapPath =
            isRoot ? posixRel : 'package:${pkg.name}/$posixRel';
        if (ignoreRules.isIgnored(snapPath) ||
            ignoreRules.isIgnored(posixRel)) {
          continue;
        }

        final key = '${pkg.name}|$posixRel';
        if (!seen.add(key)) continue;

        final file = File(abs);
        if (!file.existsSync()) continue;

        final bytes = file.readAsBytesSync();
        resources.add(
          ScannedAsset(
            package: pkg.name,
            packageHash: packageHash,
            path: posixRel,
            size: bytes.length,
            hash: sha256.convert(bytes).toString(),
          ),
        );
      }
    }
  }

  resources.sort((a, b) {
    final byPkg = a.package.compareTo(b.package);
    if (byPkg != 0) return byPkg;
    return a.path.compareTo(b.path);
  });

  final output = outPath == null || outPath.isEmpty
      ? p.join(root, 'flutterpatch_assets.json')
      : p.normalize(p.absolute(outPath));

  final result = ScanAssetsResult(
    appDir: root,
    resources: resources,
    outPath: output,
    releaseVersion: releaseVersion,
  );

  if (writeConfig) {
    final outFile = File(output);
    outFile.parent.createSync(recursive: true);
    outFile.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(result.toJson())}\n',
    );
  }

  return result;
}

class _PackageRef {
  _PackageRef({required this.name, required this.rootUri});

  final String name;
  final String rootUri;
}

Map<String, _PackageRef> _loadPackages(File packageConfigFile) {
  final raw = jsonDecode(packageConfigFile.readAsStringSync()) as Map<String, dynamic>;
  final list = raw['packages'] as List<dynamic>? ?? const [];
  final out = <String, _PackageRef>{};

  for (final item in list) {
    if (item is! Map) continue;
    final name = item['name'] as String?;
    final rootUri = item['rootUri'] as String?;
    if (name == null || rootUri == null) continue;

    if (_isSdkPackage(name, rootUri)) continue;

    final resolved = _resolvePackageRoot(
      packageConfigPath: packageConfigFile.path,
      rootUri: rootUri,
    );
    if (resolved == null) continue;
    out[name] = _PackageRef(name: name, rootUri: resolved);
  }
  return out;
}

/// A package (app root or dependency) eligible for asset / OTA scanning.
class ScannablePackage {
  ScannablePackage({
    required this.name,
    required this.rootUri,
    required this.isRoot,
    this.packageHash,
  });

  final String name;
  final String rootUri;
  final bool isRoot;

  /// Hosted package sha256 from `pubspec.lock`, if any.
  final String? packageHash;
}

/// List app + dependency packages for scanning (skips Flutter/Dart SDK packages).
///
/// Requires `flutter pub get` (`.dart_tool/package_config.json`).
/// By default skips `direct dev` packages; pass [includeDev] to include them.
List<ScannablePackage> listScannablePackages({
  required String appDir,
  bool includeDev = false,
}) {
  final root = p.normalize(p.absolute(appDir));
  final packageConfigFile = File(p.join(root, '.dart_tool', 'package_config.json'));
  if (!packageConfigFile.existsSync()) {
    throw StateError(
      '缺少 .dart_tool/package_config.json，请先在工程目录执行: flutter pub get',
    );
  }

  final lockFile = File(p.join(root, 'pubspec.lock'));
  final lockHashes = _loadPackageHashes(lockFile);
  final lockKinds = _loadPackageDependencyKinds(lockFile);
  final packages = _loadPackages(packageConfigFile);

  final pubspecFile = File(p.join(root, 'pubspec.yaml'));
  var rootName = p.basename(root);
  if (pubspecFile.existsSync()) {
    final match = RegExp(
      r'^name:\s*([^\s#]+)',
      multiLine: true,
    ).firstMatch(pubspecFile.readAsStringSync());
    final name = match?.group(1)?.trim();
    if (name != null && name.isNotEmpty) rootName = name;
  }

  packages.putIfAbsent(
    rootName,
    () => _PackageRef(name: rootName, rootUri: root),
  );

  final out = <ScannablePackage>[];
  for (final pkg in packages.values) {
    if (!_shouldIncludePackage(
      name: pkg.name,
      rootName: rootName,
      includeDev: includeDev,
      lockKinds: lockKinds,
    )) {
      continue;
    }
    out.add(
      ScannablePackage(
        name: pkg.name,
        rootUri: pkg.rootUri,
        isRoot: pkg.name == rootName,
        packageHash: lockHashes[pkg.name],
      ),
    );
  }
  out.sort((a, b) {
    if (a.isRoot != b.isRoot) return a.isRoot ? -1 : 1;
    return a.name.compareTo(b.name);
  });
  return out;
}

/// package name → absolute package root (from `.dart_tool/package_config.json`).
Map<String, String> loadPackageRoots(String appDir) {
  return {
    for (final pkg in listScannablePackages(appDir: appDir, includeDev: true))
      pkg.name: pkg.rootUri,
  };
}

const _sdkPackageNames = {
  'flutter',
  'flutter_test',
  'flutter_driver',
  'flutter_localizations',
  'flutter_web_plugins',
  'sky_engine',
};

bool _isSdkPackage(String name, String rootUri) {
  if (rootUri.startsWith('flutter:') || rootUri.startsWith('dart:')) {
    return true;
  }
  return _sdkPackageNames.contains(name);
}

String? _resolvePackageRoot({
  required String packageConfigPath,
  required String rootUri,
}) {
  if (rootUri.startsWith('file:')) {
    final uri = Uri.parse(rootUri);
    return p.normalize(uri.toFilePath());
  }
  // Relative to package_config.json location (.dart_tool/).
  final base = p.dirname(packageConfigPath);
  return p.normalize(p.absolute(p.join(base, rootUri)));
}

/// Hosted package sha256 from pubspec.lock description.
Map<String, String> _loadPackageHashes(File lockFile) {
  final out = <String, String>{};
  if (!lockFile.existsSync()) return out;

  final doc = loadYaml(lockFile.readAsStringSync());
  if (doc is! YamlMap) return out;
  final packages = doc['packages'];
  if (packages is! YamlMap) return out;

  packages.forEach((key, value) {
    final name = key?.toString();
    if (name == null || value is! YamlMap) return;
    final description = value['description'];
    if (description is YamlMap) {
      final hash = description['sha256']?.toString();
      if (hash != null && hash.isNotEmpty) {
        out[name] = hash;
      }
    }
  });
  return out;
}

Map<String, String> _loadPackageDependencyKinds(File lockFile) {
  final out = <String, String>{};
  if (!lockFile.existsSync()) return out;

  final doc = loadYaml(lockFile.readAsStringSync());
  if (doc is! YamlMap) return out;
  final packages = doc['packages'];
  if (packages is! YamlMap) return out;

  packages.forEach((key, value) {
    final name = key?.toString();
    if (name == null || value is! YamlMap) return;
    final dep = value['dependency']?.toString();
    if (dep != null) out[name] = dep;
  });
  return out;
}

bool _shouldIncludePackage({
  required String name,
  required String rootName,
  required bool includeDev,
  required Map<String, String> lockKinds,
}) {
  if (name == rootName) return true;
  if (includeDev) return true;
  final kind = lockKinds[name];
  if (kind == null) return true; // unknown → include
  // Skip packages only pulled in as direct/transitive of pure-dev when marked
  // "direct dev". Transitive of main stay included.
  return kind != 'direct dev';
}

/// Collect asset + font paths declared under `flutter:` in a pubspec.
List<String> assetPathsFromPubspec(String contents) {
  final doc = loadYaml(contents);
  if (doc is! YamlMap) return const [];
  final flutter = doc['flutter'];
  if (flutter is! YamlMap) return const [];

  final paths = <String>[];

  final assets = flutter['assets'];
  if (assets is YamlList) {
    for (final item in assets) {
      if (item is String && item.isNotEmpty) {
        paths.add(item);
      } else if (item is YamlMap) {
        // Rare map form; ignore non-string entries.
        final path = item['path']?.toString() ?? item['asset']?.toString();
        if (path != null && path.isNotEmpty) paths.add(path);
      }
    }
  }

  final fonts = flutter['fonts'];
  if (fonts is YamlList) {
    for (final family in fonts) {
      if (family is! YamlMap) continue;
      final files = family['fonts'];
      if (files is! YamlList) continue;
      for (final f in files) {
        if (f is! YamlMap) continue;
        final asset = f['asset']?.toString();
        if (asset != null && asset.isNotEmpty) paths.add(asset);
      }
    }
  }

  return paths;
}

/// Expand a pubspec asset entry to concrete files (Flutter: directory = one level).
Iterable<String> expandAssetEntry(String packageRoot, String entry) sync* {
  final normalized = entry.replaceAll('\\', '/');
  final abs = p.join(packageRoot, normalized);

  if (normalized.endsWith('/')) {
    final dir = Directory(abs);
    if (!dir.existsSync()) return;
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is File) {
        yield p.relative(entity.path, from: packageRoot).replaceAll('\\', '/');
      }
    }
    return;
  }

  final file = File(abs);
  if (file.existsSync()) {
    yield normalized;
    return;
  }

  // Directory listed without trailing slash — treat like directory listing.
  final dir = Directory(abs);
  if (dir.existsSync()) {
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is File) {
        yield p.relative(entity.path, from: packageRoot).replaceAll('\\', '/');
      }
    }
  }
}

/// Load resources list from a scan-assets JSON file.
List<ScannedAsset> loadScannedAssetsFromFile(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError('资源配置文件不存在: $path');
  }
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map) {
    throw StateError('无效的资源配置 JSON: $path');
  }
  final list = decoded['resources'];
  if (list is! List) return const [];
  return list.map((e) {
    final m = Map<String, dynamic>.from(e as Map);
    return ScannedAsset(
      package: m['package'] as String? ?? '',
      packageHash: m['package_hash'] as String?,
      path: m['path'] as String? ?? '',
      size: (m['size'] as num?)?.toInt() ?? 0,
      hash: m['hash'] as String? ?? '',
    );
  }).toList();
}

/// Diff two asset inventories → patch `changed_resources` entries.
///
/// Each entry: `{package, path, hash, size, package_hash, change}` where
/// `change` is `add` | `update` | `remove`.
List<Map<String, Object?>> diffScannedAssets({
  required List<ScannedAsset> baseline,
  required List<ScannedAsset> next,
}) {
  String key(ScannedAsset a) => '${a.package}|${a.path}';
  final baseMap = {for (final a in baseline) key(a): a};
  final nextMap = {for (final a in next) key(a): a};
  final changes = <Map<String, Object?>>[];

  for (final entry in nextMap.entries) {
    final prev = baseMap[entry.key];
    final cur = entry.value;
    if (prev == null) {
      changes.add({
        'package': cur.package,
        'package_hash': cur.packageHash,
        'path': cur.path,
        'size': cur.size,
        'hash': cur.hash,
        'change': 'add',
      });
    } else if (prev.hash != cur.hash || prev.size != cur.size) {
      changes.add({
        'package': cur.package,
        'package_hash': cur.packageHash,
        'path': cur.path,
        'size': cur.size,
        'hash': cur.hash,
        'change': 'update',
      });
    }
  }

  for (final entry in baseMap.entries) {
    if (nextMap.containsKey(entry.key)) continue;
    final prev = entry.value;
    changes.add({
      'package': prev.package,
      'package_hash': prev.packageHash,
      'path': prev.path,
      'size': prev.size,
      'hash': prev.hash,
      'change': 'remove',
    });
  }

  changes.sort((a, b) {
    final pkg = '${a['package']}'.compareTo('${b['package']}');
    if (pkg != 0) return pkg;
    final path = '${a['path']}'.compareTo('${b['path']}');
    if (path != 0) return path;
    return '${a['change']}'.compareTo('${b['change']}');
  });
  return changes;
}
