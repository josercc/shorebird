// flutterpatch: ownership=OURS — from meta_ota
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'ignore_rules.dart';
import 'scan_assets.dart';

/// Snapshot schema version written to `flutterpatch_snapshot.json`.
///
/// v2: includes Flutter dependency packages (Dart / assets / native).
const int otaSnapshotVersion = 2;

/// File categories that Meta / Shorebird-style OTA can patch.
const Set<String> otaPatchableCategories = {'flutter_dart', 'flutter_assets'};

/// Categories that require a new store release (native / platform).
const Set<String> otaBlockingCategories = {
  'android',
  'ios',
  'flutter_native',
};

class OtaFileEntry {
  OtaFileEntry({
    required this.path,
    required this.hash,
    required this.size,
    required this.category,
  });

  final String path;
  final String hash;
  final int size;

  /// One of: flutter_dart, flutter_assets, flutter_native, android, ios.
  final String category;

  Map<String, dynamic> toJson() => {
        'path': path,
        'hash': hash,
        'size': size,
        'category': category,
      };

  static OtaFileEntry fromJson(Map<String, dynamic> json) => OtaFileEntry(
        path: json['path'] as String,
        hash: json['hash'] as String,
        size: json['size'] as int? ?? 0,
        category: json['category'] as String,
      );
}

class OtaSnapshot {
  OtaSnapshot({
    required this.flutterDir,
    this.androidDir,
    this.iosDir,
    required this.files,
    DateTime? generatedAt,
    this.version = otaSnapshotVersion,
  }) : generatedAt = generatedAt ?? DateTime.now().toUtc();

  final int version;
  final DateTime generatedAt;
  final String flutterDir;
  final String? androidDir;
  final String? iosDir;
  final List<OtaFileEntry> files;

  Map<String, String> get hashByKey => {
        for (final f in files) '${f.category}:${f.path}': f.hash,
      };

  Map<String, dynamic> toJson() => {
        'version': version,
        'generated_at': generatedAt.toIso8601String(),
        'paths': {
          'flutter': flutterDir,
          if (androidDir != null) 'android': androidDir,
          if (iosDir != null) 'ios': iosDir,
        },
        'summary': _summaryCounts(),
        'files': files.map((f) => f.toJson()).toList(),
      };

  Map<String, int> _summaryCounts() {
    final counts = <String, int>{};
    for (final f in files) {
      counts[f.category] = (counts[f.category] ?? 0) + 1;
    }
    return counts;
  }

  static OtaSnapshot fromJson(Map<String, dynamic> json) {
    final pathsRaw = json['paths'];
    final paths = pathsRaw is Map
        ? Map<String, dynamic>.from(pathsRaw)
        : <String, dynamic>{};
    final rawFiles = json['files'] as List<dynamic>? ?? const [];
    return OtaSnapshot(
      version: json['version'] as int? ?? 1,
      generatedAt: DateTime.tryParse(json['generated_at'] as String? ?? '') ??
          DateTime.now().toUtc(),
      flutterDir: paths['flutter'] as String? ?? '',
      androidDir: paths['android'] as String?,
      iosDir: paths['ios'] as String?,
      files: [
        for (final item in rawFiles)
          if (item is Map) OtaFileEntry.fromJson(Map<String, dynamic>.from(item)),
      ],
    );
  }

  static OtaSnapshot load(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw StateError('找不到基线快照: $path');
    }
    final raw = jsonDecode(file.readAsStringSync());
    if (raw is! Map<String, dynamic>) {
      throw StateError('快照格式无效: $path');
    }
    return OtaSnapshot.fromJson(raw);
  }
}

enum FileChangeKind { added, removed, modified }

class FileChange {
  FileChange({
    required this.kind,
    required this.category,
    required this.path,
    this.oldHash,
    this.newHash,
  });

  final FileChangeKind kind;
  final String category;
  final String path;
  final String? oldHash;
  final String? newHash;

  bool get isPatchable => otaPatchableCategories.contains(category);
  bool get isBlocking => otaBlockingCategories.contains(category);

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'category': category,
        'path': path,
        if (oldHash != null) 'old_hash': oldHash,
        if (newHash != null) 'new_hash': newHash,
        'ota_patchable': isPatchable,
      };
}

/// Result of scanning (and optionally comparing against a baseline).
class CheckOtaResult {
  CheckOtaResult({
    required this.snapshot,
    required this.outPath,
    this.baselinePath,
    this.baselineSource,
    this.releaseVersion,
    this.serverSnapshotNumber,
    this.serverResourceNumber,
    this.changes = const [],
    this.assetChanges = const [],
  });

  final OtaSnapshot snapshot;
  final String outPath;

  /// Local file path used as baseline, if any.
  final String? baselinePath;

  /// `local` | `server` | null (no baseline).
  final String? baselineSource;

  final String? releaseVersion;
  final int? serverSnapshotNumber;
  final int? serverResourceNumber;
  final List<FileChange> changes;

  /// Asset inventory diff vs server/local resource config (`add`/`update`/`remove`).
  final List<Map<String, Object?>> assetChanges;

  bool get hasBaseline => baselineSource != null;

  bool get hasChanges => changes.isNotEmpty || assetChanges.isNotEmpty;

  List<FileChange> get patchableChanges =>
      changes.where((c) => c.isPatchable).toList();

  List<FileChange> get blockingChanges =>
      changes.where((c) => c.isBlocking).toList();

  /// `true` only when a baseline exists and there are patchable Dart/asset
  /// changes with no native/platform blockers. No baseline, no changes, or any
  /// blocking change → `false` (cannot / need not ship an OTA patch).
  bool get otaSupported {
    if (!hasBaseline) return false;
    if (blockingChanges.isNotEmpty) return false;
    return patchableChanges.isNotEmpty || assetChanges.isNotEmpty;
  }

  Map<String, dynamic> toJson() => {
        'out_path': outPath,
        if (baselinePath != null) 'baseline_path': baselinePath,
        if (baselineSource != null) 'baseline_source': baselineSource,
        if (releaseVersion != null) 'release_version': releaseVersion,
        if (serverSnapshotNumber != null)
          'server_snapshot_number': serverSnapshotNumber,
        if (serverResourceNumber != null)
          'server_resource_number': serverResourceNumber,
        'ota_supported': otaSupported,
        'has_baseline': hasBaseline,
        'change_count': changes.length,
        'patchable_change_count': patchableChanges.length,
        'blocking_change_count': blockingChanges.length,
        'asset_change_count': assetChanges.length,
        'changes': changes.map((c) => c.toJson()).toList(),
        'asset_changes': assetChanges,
        'snapshot_summary': snapshot._summaryCounts(),
      };
}

/// Scan Flutter / Android / iOS trees into a snapshot; compare with previous if present.
///
/// Flutter scan covers the app package **and** its pub dependencies (Dart, assets,
/// and native sources under each package). Root-package paths stay relative to the
/// Flutter dir; dependency paths use `package:<name>/<rel>`.
///
/// Baseline priority:
/// 1. [baselineSnapshot] (e.g. downloaded from control plane)
/// 2. [baselinePath] file
/// 3. existing [outPath] local file (unless [skipLocalBaseline])
Future<CheckOtaResult> checkOta({
  required String flutterDir,
  String? androidDir,
  String? iosDir,
  String? outPath,
  String? baselinePath,
  OtaSnapshot? baselineSnapshot,
  String? baselineSourceLabel,
  String? releaseVersion,
  int? serverSnapshotNumber,
  int? serverResourceNumber,
  List<Map<String, Object?>> assetChanges = const [],
  bool writeSnapshot = true,
  bool skipLocalBaseline = false,
  bool includeDev = false,
  FlutterPatchIgnore? ignore,
}) async {
  final flutter = p.normalize(p.absolute(flutterDir));
  final android =
      androidDir == null || androidDir.isEmpty ? null : p.normalize(p.absolute(androidDir));
  final ios = iosDir == null || iosDir.isEmpty ? null : p.normalize(p.absolute(iosDir));

  _requireDir(flutter, label: 'flutter');
  if (android != null) _requireDir(android, label: 'android');
  if (ios != null) _requireDir(ios, label: 'ios');

  final pubspec = File(p.join(flutter, 'pubspec.yaml'));
  if (!pubspec.existsSync()) {
    throw StateError('不是 Flutter 工程：缺少 pubspec.yaml ($flutter)');
  }

  final ignoreRules = ignore ?? FlutterPatchIgnore.load(flutter);

  final packages = listScannablePackages(
    appDir: flutter,
    includeDev: includeDev,
  );

  final files = <OtaFileEntry>[
    ..._scanPackagesDart(packages, ignore: ignoreRules),
    ..._scanPackagesAssets(packages, ignore: ignoreRules),
    ..._scanPackagesNative(packages, ignore: ignoreRules),
    if (android != null) ..._scanAndroid(android, ignore: ignoreRules),
    if (ios != null) ..._scanIos(ios, ignore: ignoreRules),
  ];

  files.sort((a, b) {
    final byCat = a.category.compareTo(b.category);
    if (byCat != 0) return byCat;
    return a.path.compareTo(b.path);
  });

  final snapshot = OtaSnapshot(
    flutterDir: flutter,
    androidDir: android,
    iosDir: ios,
    files: files,
  );

  final output = outPath == null || outPath.isEmpty
      ? p.join(flutter, 'flutterpatch_snapshot.json')
      : p.normalize(p.absolute(outPath));

  OtaSnapshot? baseline = baselineSnapshot;
  String? usedBaselinePath;
  String? usedSource = baselineSnapshot != null
      ? (baselineSourceLabel ?? 'server')
      : null;

  if (baseline == null) {
    String? resolvedBaseline = baselinePath;
    if (resolvedBaseline == null || resolvedBaseline.isEmpty) {
      if (!skipLocalBaseline && File(output).existsSync()) {
        resolvedBaseline = output;
      }
    } else {
      resolvedBaseline = p.normalize(p.absolute(resolvedBaseline));
    }
    if (resolvedBaseline != null && File(resolvedBaseline).existsSync()) {
      baseline = OtaSnapshot.load(resolvedBaseline);
      usedBaselinePath = resolvedBaseline;
      usedSource = 'local';
    }
  }

  final changes =
      baseline == null ? const <FileChange>[] : compareOtaSnapshots(baseline, snapshot);

  if (writeSnapshot) {
    final outFile = File(output);
    outFile.parent.createSync(recursive: true);
    outFile.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(snapshot.toJson())}\n',
    );
  }

  return CheckOtaResult(
    snapshot: snapshot,
    outPath: output,
    baselinePath: usedBaselinePath,
    baselineSource: usedSource,
    releaseVersion: releaseVersion,
    serverSnapshotNumber: serverSnapshotNumber,
    serverResourceNumber: serverResourceNumber,
    changes: changes,
    assetChanges: assetChanges,
  );
}

List<FileChange> compareOtaSnapshots(OtaSnapshot baseline, OtaSnapshot current) {
  final oldMap = {
    for (final f in baseline.files) '${f.category}:${f.path}': f,
  };
  final newMap = {
    for (final f in current.files) '${f.category}:${f.path}': f,
  };

  final changes = <FileChange>[];
  final keys = {...oldMap.keys, ...newMap.keys}.toList()..sort();

  for (final key in keys) {
    final old = oldMap[key];
    final neu = newMap[key];
    if (old == null && neu != null) {
      changes.add(FileChange(
        kind: FileChangeKind.added,
        category: neu.category,
        path: neu.path,
        newHash: neu.hash,
      ));
    } else if (old != null && neu == null) {
      changes.add(FileChange(
        kind: FileChangeKind.removed,
        category: old.category,
        path: old.path,
        oldHash: old.hash,
      ));
    } else if (old != null && neu != null && old.hash != neu.hash) {
      changes.add(FileChange(
        kind: FileChangeKind.modified,
        category: neu.category,
        path: neu.path,
        oldHash: old.hash,
        newHash: neu.hash,
      ));
    }
  }
  return changes;
}

void printCheckOtaReport(CheckOtaResult result) {
  final snap = result.snapshot;
  stdout.writeln('==> 扫描完成');
  stdout.writeln('    Flutter : ${snap.flutterDir}');
  if (snap.androidDir != null) stdout.writeln('    Android : ${snap.androidDir}');
  if (snap.iosDir != null) stdout.writeln('    iOS     : ${snap.iosDir}');
  stdout.writeln('    文件数  : ${snap.files.length} → ${result.outPath}');
  if (result.releaseVersion != null) {
    stdout.writeln('    版本    : ${result.releaseVersion}');
  }

  if (!result.hasBaseline) {
    stdout.writeln('');
    stdout.writeln(
      '已写入本地快照。请用 upload-snapshot / upload-resources 上传到对应版本，'
      '或下次带 --version 从服务器拉基线对比。',
    );
    stdout.writeln('OTA 支持: 否（无基线，无法判断可热更变动）');
    return;
  }

  stdout.writeln('');
  if (result.baselineSource == 'server') {
    final sn = result.serverSnapshotNumber;
    stdout.writeln(
      '对比基线: 服务器快照'
      '${sn != null ? ' #$sn' : ''}'
      '${result.releaseVersion != null ? ' (${result.releaseVersion})' : ''}',
    );
  } else {
    stdout.writeln('对比基线: ${result.baselinePath}');
  }

  if (!result.hasChanges) {
    stdout.writeln('无文件变动。');
    stdout.writeln('OTA 支持: 否（无变动，无需发补丁）');
    return;
  }

  void dump(String title, List<FileChange> list) {
    if (list.isEmpty) return;
    stdout.writeln('');
    stdout.writeln('$title (${list.length}):');
    for (final c in list) {
      final tag = switch (c.kind) {
        FileChangeKind.added => '+',
        FileChangeKind.removed => '-',
        FileChangeKind.modified => '~',
      };
      stdout.writeln('  $tag [${c.category}] ${c.path}');
    }
  }

  dump('可 OTA（Dart / 资源文件）', result.patchableChanges);
  dump('不可 OTA（原生 / 平台）', result.blockingChanges);

  final other = result.changes
      .where((c) => !c.isPatchable && !c.isBlocking)
      .toList();
  dump('其他变动', other);

  if (result.assetChanges.isNotEmpty) {
    stdout.writeln('');
    stdout.writeln('资源配置变动 (${result.assetChanges.length}):');
    for (final c in result.assetChanges.take(50)) {
      stdout.writeln(
        '  ${c['change']} ${c['package']}/${c['path']}',
      );
    }
    if (result.assetChanges.length > 50) {
      stdout.writeln('  … 另有 ${result.assetChanges.length - 50} 条');
    }
  }

  stdout.writeln('');
  if (result.otaSupported) {
    stdout.writeln('OTA 支持: 是（仅 Flutter Dart / 资源变动，含依赖包）');
  } else if (result.blockingChanges.isNotEmpty) {
    stdout.writeln('OTA 支持: 否（检测到 Android / iOS / Flutter 原生相关变动，需重新打 release）');
  } else {
    stdout.writeln('OTA 支持: 否（无可热更变动）');
  }
}

void _requireDir(String path, {required String label}) {
  if (!Directory(path).existsSync()) {
    throw StateError('$label 目录不存在: $path');
  }
}

/// Snapshot path for a file: root package keeps app-relative paths; deps use
/// `package:<name>/<rel>`.
String _snapshotPath(ScannablePackage pkg, String relativePosix) {
  if (pkg.isRoot) return relativePosix;
  return 'package:${pkg.name}/$relativePosix';
}

List<OtaFileEntry> _scanPackagesDart(
  List<ScannablePackage> packages, {
  required FlutterPatchIgnore ignore,
}) {
  final out = <OtaFileEntry>[];
  for (final pkg in packages) {
    final libDir = Directory(p.join(pkg.rootUri, 'lib'));
    if (!libDir.existsSync()) continue;

    for (final entity in libDir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (!_hasExtension(entity.path, const {'.dart'})) continue;
      final rel =
          p.relative(entity.path, from: pkg.rootUri).replaceAll('\\', '/');
      if (_shouldSkipPath(rel)) continue;
      final snapPath = _snapshotPath(pkg, rel);
      if (ignore.isIgnored(snapPath) || ignore.isIgnored(rel)) continue;
      out.add(_hashFile(
        root: pkg.rootUri,
        file: entity,
        category: 'flutter_dart',
        relativePath: snapPath,
      ));
    }
  }
  return out;
}

List<OtaFileEntry> _scanPackagesAssets(
  List<ScannablePackage> packages, {
  required FlutterPatchIgnore ignore,
}) {
  final out = <OtaFileEntry>[];
  final seen = <String>{};

  for (final pkg in packages) {
    final pubspec = File(p.join(pkg.rootUri, 'pubspec.yaml'));
    if (!pubspec.existsSync()) continue;
    final assetEntries = assetPathsFromPubspec(pubspec.readAsStringSync());

    for (final entry in assetEntries) {
      for (final rel in expandAssetEntry(pkg.rootUri, entry)) {
        final key = _snapshotPath(pkg, rel);
        if (ignore.isIgnored(key) || ignore.isIgnored(rel)) continue;
        if (!seen.add(key)) continue;
        final file = File(p.join(pkg.rootUri, rel));
        if (!file.existsSync()) continue;
        out.add(_hashFile(
          root: pkg.rootUri,
          file: file,
          category: 'flutter_assets',
          relativePath: key,
        ));
      }
    }
  }
  return out;
}

const _nativeExt = {
  '.kt',
  '.kts',
  '.java',
  '.swift',
  '.m',
  '.mm',
  '.h',
  '.hpp',
  '.c',
  '.cc',
  '.cpp',
  '.cxx',
};

/// Native sources in the app package (excludes top-level android/ios — those
/// are scanned via --android/--ios) and in dependency packages (includes their
/// android/ios plugin sources).
List<OtaFileEntry> _scanPackagesNative(
  List<ScannablePackage> packages, {
  required FlutterPatchIgnore ignore,
}) {
  const skipTopRoot = {
    'android',
    'ios',
    'macos',
    'linux',
    'windows',
    'web',
    'build',
    '.dart_tool',
    '.git',
    '.idea',
    '.vscode',
    'test',
    'integration_test',
  };
  const skipDirAny = {
    'build',
    '.dart_tool',
    '.git',
    '.idea',
    '.vscode',
    'example',
    'test',
    'Pods',
    '.symlinks',
    'DerivedData',
    '.gradle',
    '.cxx',
  };

  final out = <OtaFileEntry>[];

  for (final pkg in packages) {
    final rootDir = Directory(pkg.rootUri);
    if (!rootDir.existsSync()) continue;

    void walk(Directory current, {required bool skipPlatformTops}) {
      for (final entity in current.listSync(followLinks: false)) {
        final name = p.basename(entity.path);
        if (name.startsWith('.') && name != '.gitignore') {
          if (entity is Directory) continue;
        }
        if (entity is Directory) {
          if (skipDirAny.contains(name)) continue;
          if (skipPlatformTops && skipTopRoot.contains(name)) continue;
          walk(entity, skipPlatformTops: false);
          continue;
        }
        if (entity is! File) continue;
        if (!_hasExtension(entity.path, _nativeExt)) continue;
        final rel =
            p.relative(entity.path, from: pkg.rootUri).replaceAll('\\', '/');
        if (_shouldSkipPath(rel)) continue;
        final snapPath = _snapshotPath(pkg, rel);
        if (ignore.isIgnored(snapPath) || ignore.isIgnored(rel)) continue;
        out.add(_hashFile(
          root: pkg.rootUri,
          file: entity,
          category: 'flutter_native',
          relativePath: snapPath,
        ));
      }
    }

    // Root app: do not re-scan android/ios (passed separately). Deps: include
    // plugin android/ios native sources so native plugin changes block OTA.
    walk(rootDir, skipPlatformTops: pkg.isRoot);
  }
  return out;
}

List<OtaFileEntry> _scanAndroid(
  String androidRoot, {
  required FlutterPatchIgnore ignore,
}) {
  const includeExt = {
    '.kt',
    '.kts',
    '.java',
    '.xml',
    '.gradle',
    '.properties',
    '.pro',
    '.c',
    '.cc',
    '.cpp',
    '.cxx',
    '.h',
    '.hpp',
    '.cmake',
  };
  const includeNames = {
    'AndroidManifest.xml',
    'Proguard.cfg',
    'proguard-rules.pro',
    'CMakeLists.txt',
    'build.gradle',
    'build.gradle.kts',
    'settings.gradle',
    'settings.gradle.kts',
  };

  return _scanTree(
    root: androidRoot,
    category: 'android',
    includeExt: includeExt,
    includeNames: includeNames,
    skipDirNames: const {
      'build',
      '.gradle',
      '.cxx',
      '.idea',
      'captures',
      'local.properties',
    },
    ignore: ignore,
  );
}

List<OtaFileEntry> _scanIos(
  String iosRoot, {
  required FlutterPatchIgnore ignore,
}) {
  const includeExt = {
    '.swift',
    '.m',
    '.mm',
    '.h',
    '.hpp',
    '.c',
    '.cc',
    '.cpp',
    '.pbxproj',
    '.xcconfig',
    '.plist',
    '.entitlements',
    '.storyboard',
    '.xib',
  };
  const includeNames = {
    'Podfile',
    'Podfile.lock',
    'Package.swift',
  };

  return _scanTree(
    root: iosRoot,
    category: 'ios',
    includeExt: includeExt,
    includeNames: includeNames,
    skipDirNames: const {
      'Pods',
      '.symlinks',
      'DerivedData',
      'build',
      'Flutter',
      '.git',
    },
    ignore: ignore,
  );
}

List<OtaFileEntry> _scanTree({
  required String root,
  required String category,
  required Set<String> includeExt,
  required Set<String> includeNames,
  required Set<String> skipDirNames,
  required FlutterPatchIgnore ignore,
}) {
  final out = <OtaFileEntry>[];
  final dir = Directory(root);
  if (!dir.existsSync()) return out;

  void walk(Directory current) {
    for (final entity in current.listSync(followLinks: false)) {
      final name = p.basename(entity.path);
      if (name.startsWith('.') && name != '.gitignore') {
        // Skip hidden dirs/files except we may want some; skip all for stability.
        if (entity is Directory) continue;
      }
      if (entity is Directory) {
        if (skipDirNames.contains(name)) continue;
        walk(entity);
        continue;
      }
      if (entity is! File) continue;
      final rel = p.relative(entity.path, from: root).replaceAll('\\', '/');
      if (_shouldSkipPath(rel)) continue;
      if (ignore.isIgnored(rel)) continue;

      final base = p.basename(entity.path);
      final matchName = includeNames.contains(base);
      final matchExt = _hasExtension(entity.path, includeExt);
      if (!matchName && !matchExt) continue;

      out.add(_hashFile(
        root: root,
        file: entity,
        category: category,
        relativePath: rel,
      ));
    }
  }

  walk(dir);
  return out;
}

OtaFileEntry _hashFile({
  required String root,
  required File file,
  required String category,
  String? relativePath,
}) {
  final rel = (relativePath ?? p.relative(file.path, from: root))
      .replaceAll('\\', '/');
  final bytes = file.readAsBytesSync();
  return OtaFileEntry(
    path: rel,
    hash: sha256.convert(bytes).toString(),
    size: bytes.length,
    category: category,
  );
}

bool _hasExtension(String path, Set<String> exts) {
  final ext = p.extension(path).toLowerCase();
  return exts.contains(ext);
}

bool _shouldSkipPath(String relativePosix) {
  final parts = relativePosix.split('/');
  for (final part in parts) {
    if (part == 'build' ||
        part == '.dart_tool' ||
        part == '.git' ||
        part == 'Pods' ||
        part == '.symlinks' ||
        part == 'DerivedData' ||
        part == '.gradle' ||
        part == '.cxx') {
      return true;
    }
  }
  return false;
}
