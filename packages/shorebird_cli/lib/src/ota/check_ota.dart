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

  /// Whether this entry matters for an Android / iOS scoped check.
  bool isRelevantForPlatform(String? platform) =>
      isOtaPathRelevantForPlatform(
        category: category,
        path: path,
        platform: platform,
      );

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
    this.resources = const [],
    this.assetChanges = const [],
    this.unsupportedAssetChanges = const [],
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

  /// Full local Flutter asset inventory (current scan; not a diff).
  ///
  /// Each entry matches [ScannedAsset.toJson] (`package`, `path`, `hash`, …).
  final List<Map<String, Object?>> resources;

  /// Hot-updatable asset inventory diff (`add`/`update`/`remove`).
  final List<Map<String, Object?>> assetChanges;

  /// Asset changes matching `.flutterpatch-unsupported-resources` (cannot hot-update).
  final List<Map<String, Object?>> unsupportedAssetChanges;

  bool get hasBaseline => baselineSource != null;

  bool get hasChanges =>
      changes.isNotEmpty ||
      assetChanges.isNotEmpty ||
      unsupportedAssetChanges.isNotEmpty;

  List<FileChange> get patchableChanges =>
      changes.where((c) => c.isPatchable).toList();

  List<FileChange> get blockingChanges =>
      changes.where((c) => c.isBlocking).toList();

  /// `true` only when a baseline exists and there are patchable Dart/asset
  /// changes with no native/platform blockers and no unsupported asset
  /// changes. No baseline, no changes, or any blocker → `false`.
  bool get otaSupported {
    if (!hasBaseline) return false;
    if (blockingChanges.isNotEmpty) return false;
    if (unsupportedAssetChanges.isNotEmpty) return false;
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
        'resource_count': resources.length,
        'asset_change_count': assetChanges.length,
        'unsupported_asset_change_count': unsupportedAssetChanges.length,
        'changes': changes.map((c) => c.toJson()).toList(),
        'resources': resources,
        'asset_changes': assetChanges,
        'unsupported_asset_changes': unsupportedAssetChanges,
        'snapshot_summary': snapshot._summaryCounts(),
      };

  /// JSON payload of native/platform (non-OTA) file changes only.
  Map<String, dynamic> unsupportedFilesToJson() => {
        'ota_supported': otaSupported,
        'blocking_change_count': blockingChanges.length,
        'unsupported_asset_change_count': unsupportedAssetChanges.length,
        'unsupported_files':
            blockingChanges.map((c) => c.toJson()).toList(),
        'unsupported_asset_changes': unsupportedAssetChanges,
      };

  /// JSON payload of Dart / Flutter-asset (OTA-patchable) file changes only.
  Map<String, dynamic> supportedFilesToJson() => {
        'ota_supported': otaSupported,
        'patchable_change_count': patchableChanges.length,
        'resource_count': resources.length,
        'asset_change_count': assetChanges.length,
        'supported_files': patchableChanges.map((c) => c.toJson()).toList(),
        'resources': resources,
        'asset_changes': assetChanges,
      };

  /// JSON payload of the hot-update resource config:
  /// full inventory + incremental changes + unsupported changes.
  Map<String, dynamic> resourcesToJson() => {
        'ota_supported': otaSupported,
        'resource_count': resources.length,
        'resources': resources,
        'asset_change_count': assetChanges.length,
        'asset_changes': assetChanges,
        'unsupported_asset_change_count': unsupportedAssetChanges.length,
        'unsupported_asset_changes': unsupportedAssetChanges,
      };
}

/// Write [CheckOtaResult.unsupportedFilesToJson] to [path].
void writeUnsupportedFilesJson(CheckOtaResult result, String path) {
  final file = File(p.normalize(p.absolute(path)));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(result.unsupportedFilesToJson())}\n',
  );
}

/// Write [CheckOtaResult.supportedFilesToJson] to [path].
void writeSupportedFilesJson(CheckOtaResult result, String path) {
  final file = File(p.normalize(p.absolute(path)));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(result.supportedFilesToJson())}\n',
  );
}

/// Write [CheckOtaResult.resourcesToJson] to [path].
void writeResourcesJson(CheckOtaResult result, String path) {
  final file = File(p.normalize(p.absolute(path)));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(result.resourcesToJson())}\n',
  );
}

/// Whether a snapshot path/category is relevant for a platform-scoped check.
///
/// When [platform] is null, everything is relevant. When `android` / `ios`,
/// the opposite platform tree (and unrelated desktop plugin natives) are
/// excluded so an Android check does not surface Swift/iOS noise.
bool isOtaPathRelevantForPlatform({
  required String category,
  required String path,
  String? platform,
}) {
  final normalized = platform?.trim().toLowerCase();
  if (normalized == null || normalized.isEmpty) return true;

  switch (category) {
    case 'flutter_dart':
    case 'flutter_assets':
      return true;
    case 'android':
      return normalized == 'android';
    case 'ios':
      return normalized == 'ios';
    case 'flutter_native':
      return _nativePathMatchesPlatform(path, normalized);
    default:
      return true;
  }
}

bool _nativePathMatchesPlatform(String path, String platform) {
  final n = path.replaceAll('\\', '/').toLowerCase();
  var rel = n;
  if (rel.startsWith('package:')) {
    final slash = rel.indexOf('/', 'package:'.length);
    if (slash != -1) rel = rel.substring(slash + 1);
  }

  const androidMarkers = {'android'};
  const iosMarkers = {'ios', 'darwin'};
  const otherMarkers = {'macos', 'linux', 'windows', 'web'};

  for (final seg in rel.split('/')) {
    if (androidMarkers.contains(seg)) return platform == 'android';
    if (iosMarkers.contains(seg)) return platform == 'ios';
    if (otherMarkers.contains(seg)) return false;
  }
  // No platform folder marker — treat as shared / relevant to both.
  return true;
}

/// Scan Flutter / Android / iOS trees into a snapshot; compare with previous if present.
///
/// Flutter scan covers the app package **and** its pub dependencies (Dart, assets,
/// and native sources under each package). Root-package paths stay relative to the
/// Flutter dir; dependency paths use `package:<name>/<rel>`.
///
/// When [platform] is `android` or `ios`, only that platform's native/project
/// trees are scanned and compared (opposite-platform baseline entries are
/// ignored so they do not appear as removals).
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
  List<Map<String, Object?>> resources = const [],
  List<Map<String, Object?>> assetChanges = const [],
  List<Map<String, Object?>> unsupportedAssetChanges = const [],
  bool writeSnapshot = true,
  bool skipLocalBaseline = false,
  bool includeDev = false,
  FlutterPatchIgnore? ignore,
  String? platform,
}) async {
  final flutter = p.normalize(p.absolute(flutterDir));
  final normalizedPlatform = platform?.trim().toLowerCase();
  if (normalizedPlatform != null &&
      normalizedPlatform.isNotEmpty &&
      normalizedPlatform != 'android' &&
      normalizedPlatform != 'ios') {
    throw ArgumentError.value(
      platform,
      'platform',
      'must be android or ios',
    );
  }
  final scopedPlatform =
      (normalizedPlatform == null || normalizedPlatform.isEmpty)
          ? null
          : normalizedPlatform;

  // Platform-scoped checks only scan the matching project tree.
  var android = androidDir == null || androidDir.isEmpty
      ? null
      : p.normalize(p.absolute(androidDir));
  var ios =
      iosDir == null || iosDir.isEmpty ? null : p.normalize(p.absolute(iosDir));
  if (scopedPlatform == 'android') {
    ios = null;
  } else if (scopedPlatform == 'ios') {
    android = null;
  }

  _requireDir(flutter, label: 'flutter');
  if (android != null) _requireDir(android, label: 'android');
  if (ios != null) _requireDir(ios, label: 'ios');

  final pubspec = File(p.join(flutter, 'pubspec.yaml'));
  if (!pubspec.existsSync()) {
    throw StateError('不是 Flutter 工程：缺少 pubspec.yaml ($flutter)');
  }

  final ignoreRules =
      ignore ?? FlutterPatchIgnore.load(flutter, platform: scopedPlatform);

  final packages = listScannablePackages(
    appDir: flutter,
    includeDev: includeDev,
  );

  final files = <OtaFileEntry>[
    ..._scanPackagesDart(packages, ignore: ignoreRules),
    ..._scanPackagesAssets(packages, ignore: ignoreRules),
    ..._scanPackagesNative(
      packages,
      ignore: ignoreRules,
      platform: scopedPlatform,
    ),
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

  // Local ignore is authoritative for snapshot/native trees: ignored paths
  // are excluded from both sides of the diff. Platform filter likewise drops
  // opposite-platform baseline entries. Asset hot/unsupported split is done
  // by the caller via [diffAndClassifyScannedAssets].
  final changes = baseline == null
      ? const <FileChange>[]
      : compareOtaSnapshots(
          baseline,
          snapshot,
          ignore: ignoreRules,
          platform: scopedPlatform,
        );

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
    resources: resources,
    assetChanges: assetChanges,
    unsupportedAssetChanges: unsupportedAssetChanges,
  );
}

/// Compare [baseline] to [current].
///
/// When [ignore] is provided, paths matching local ignore rules are excluded
/// from both snapshots before diffing (so newly ignored baseline entries do
/// not appear as `removed` / blocking changes). When [platform] is set,
/// opposite-platform entries are excluded from both sides as well.
List<FileChange> compareOtaSnapshots(
  OtaSnapshot baseline,
  OtaSnapshot current, {
  FlutterPatchIgnore? ignore,
  String? platform,
}) {
  bool skipped(OtaFileEntry f) {
    if (!f.isRelevantForPlatform(platform)) return true;
    return ignore != null && ignore.isIgnoredSnapshotPath(f.path);
  }

  final oldMap = {
    for (final f in baseline.files)
      if (!skipped(f)) '${f.category}:${f.path}': f,
  };
  final newMap = {
    for (final f in current.files)
      if (!skipped(f)) '${f.category}:${f.path}': f,
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
  if (result.otaSupported) {
    stdout.writeln('OTA 支持: 是');
    return;
  }

  // Cannot hot-update due to native/platform changes — list only those files.
  if (result.blockingChanges.isNotEmpty) {
    stdout.writeln(
      'OTA 支持: 否（检测到 Android / iOS / Flutter 原生相关变动，无法热更，需重新打 release）',
    );
    stdout.writeln('不可热更变动 (${result.blockingChanges.length}):');
    for (final c in result.blockingChanges) {
      final tag = switch (c.kind) {
        FileChangeKind.added => '+',
        FileChangeKind.removed => '-',
        FileChangeKind.modified => '~',
      };
      stdout.writeln('  $tag [${c.category}] ${c.path}');
    }
    return;
  }

  if (result.unsupportedAssetChanges.isNotEmpty) {
    stdout.writeln(
      unsupportedResourceChangesMessage(result.unsupportedAssetChanges),
    );
    return;
  }

  if (!result.hasBaseline) {
    stdout.writeln('OTA 支持: 否（无基线，无法判断可热更变动）');
    return;
  }
  if (!result.hasChanges) {
    stdout.writeln('OTA 支持: 否（无变动，无需发补丁）');
    return;
  }
  stdout.writeln('OTA 支持: 否（无可热更变动）');
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
      if (ignore.isIgnoredSnapshotPath(snapPath)) continue;
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
        if (ignore.isIgnoredSnapshotPath(key)) continue;
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
///
/// When [platform] is `android` / `ios`, dependency plugin trees for the
/// opposite platform (and desktop) are skipped.
List<OtaFileEntry> _scanPackagesNative(
  List<ScannablePackage> packages, {
  required FlutterPatchIgnore ignore,
  String? platform,
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

  // Platform folders to skip entirely under dependency packages.
  final skipPlatformFolders = <String>{
    if (platform == 'android')
      ...{'ios', 'darwin', 'macos', 'linux', 'windows', 'web'},
    if (platform == 'ios') ...{'android', 'macos', 'linux', 'windows', 'web'},
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
          if (!pkg.isRoot && skipPlatformFolders.contains(name)) continue;
          walk(entity, skipPlatformTops: false);
          continue;
        }
        if (entity is! File) continue;
        if (!_hasExtension(entity.path, _nativeExt)) continue;
        final rel =
            p.relative(entity.path, from: pkg.rootUri).replaceAll('\\', '/');
        if (_shouldSkipPath(rel)) continue;
        final snapPath = _snapshotPath(pkg, rel);
        if (ignore.isIgnoredSnapshotPath(snapPath)) continue;
        if (!isOtaPathRelevantForPlatform(
          category: 'flutter_native',
          path: snapPath,
          platform: platform,
        )) {
          continue;
        }
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
      if (ignore.isIgnoredSnapshotPath(rel)) continue;

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
