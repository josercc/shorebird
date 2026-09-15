// flutterpatch: ownership=OURS — from meta_ota
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/ota/check_ota.dart';
import 'package:shorebird_cli/src/ota/scan_assets.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';

/// Snapshot + resource config downloaded from the control plane for one build.
class ServerBaseline {
  ServerBaseline({
    this.snapshot,
    this.snapshotMeta,
    this.resourceAssets = const [],
    this.resourceMeta,
  });

  final OtaSnapshot? snapshot;
  final Map<String, dynamic>? snapshotMeta;
  final List<ScannedAsset> resourceAssets;
  final Map<String, dynamic>? resourceMeta;

  int? get snapshotNumber => (snapshotMeta?['number'] as num?)?.toInt();
  int? get resourceNumber => (resourceMeta?['number'] as num?)?.toInt();
}

/// On-disk cache for server baseline JSON content, keyed by control-plane id.
///
/// Layout under [root]:
/// - `snapshot/<id>.json`
/// - `resource/<id>.json`
class BaselineContentCache {
  BaselineContentCache(this.root);

  /// Cache root, typically `bin/cache/flutterpatch/baselines`.
  final Directory root;

  File snapshotFile(String id) =>
      File(p.join(root.path, 'snapshot', '${_safe(id)}.json'));

  File resourceFile(String id) =>
      File(p.join(root.path, 'resource', '${_safe(id)}.json'));

  /// Returns cached bytes, or null if missing.
  List<int>? readSnapshot(String id) => _read(snapshotFile(id));

  /// Returns cached bytes, or null if missing.
  List<int>? readResource(String id) => _read(resourceFile(id));

  void writeSnapshot(String id, List<int> bytes) =>
      _write(snapshotFile(id), bytes);

  void writeResource(String id, List<int> bytes) =>
      _write(resourceFile(id), bytes);

  static List<int>? _read(File file) {
    if (!file.existsSync()) return null;
    return file.readAsBytesSync();
  }

  static void _write(File file, List<int> bytes) {
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes, flush: true);
  }

  static String _safe(String id) {
    return id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  }
}

/// Fetch latest published snapshot + resource config for [releaseVersion].
///
/// When [cache] is set, content bodies are read/written under that cache keyed
/// by snapshot/resource id. List APIs always run so the latest active id is
/// used. Pass [forceRefresh] to ignore cached bodies and re-download.
Future<ServerBaseline> fetchServerBaseline({
  required CodePushClient client,
  required String appId,
  required String releaseVersion,
  String? platform,
  BaselineContentCache? cache,
  bool forceRefresh = false,
}) async {
  OtaSnapshot? snapshot;
  Map<String, dynamic>? snapshotMeta;
  List<ScannedAsset> resourceAssets = const [];
  Map<String, dynamic>? resourceMeta;

  final snapshots = await client.listOtaSnapshots(
    appId: appId,
    releaseVersion: releaseVersion,
    platform: platform,
  );
  final activeSnaps = snapshots
      .where((e) => e['rolled_back'] != true && e['rolled_back'] != 1)
      .toList()
    ..sort(
      (a, b) => ((b['number'] as num?)?.toInt() ?? 0).compareTo(
        (a['number'] as num?)?.toInt() ?? 0,
      ),
    );

  if (activeSnaps.isNotEmpty) {
    snapshotMeta = activeSnaps.first;
    final id = snapshotMeta['id'] as String;
    final bytes = await _loadContentBytes(
      kind: 'snapshot',
      id: id,
      cache: cache,
      forceRefresh: forceRefresh,
      download: () => client.getOtaSnapshotContent(id),
      writeCache: cache == null
          ? null
          : (b) => cache.writeSnapshot(id, b),
      readCache: cache == null ? null : () => cache.readSnapshot(id),
    );
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) {
      throw StateError('Server snapshot content is not a JSON object');
    }
    snapshot = OtaSnapshot.fromJson(Map<String, dynamic>.from(decoded));
  }

  final resources = await client.listResourceSnapshots(
    appId: appId,
    releaseVersion: releaseVersion,
    platform: platform,
  );
  final activeRes = resources
      .where((e) => e['rolled_back'] != true && e['rolled_back'] != 1)
      .toList()
    ..sort(
      (a, b) => ((b['number'] as num?)?.toInt() ?? 0).compareTo(
        (a['number'] as num?)?.toInt() ?? 0,
      ),
    );

  if (activeRes.isNotEmpty) {
    resourceMeta = activeRes.first;
    final id = resourceMeta['id'] as String;
    final bytes = await _loadContentBytes(
      kind: 'resource',
      id: id,
      cache: cache,
      forceRefresh: forceRefresh,
      download: () => client.getResourceSnapshotContent(id),
      writeCache: cache == null
          ? null
          : (b) => cache.writeResource(id, b),
      readCache: cache == null ? null : () => cache.readResource(id),
    );
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is Map) {
      final list = decoded['resources'];
      if (list is List) {
        resourceAssets = list.map((e) {
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
    }
  }

  if (snapshot == null && resourceAssets.isEmpty) {
    stderr.writeln(
      'Warning: no published snapshot or resource config for version '
      '$releaseVersion. Run flutterpatch upload-snapshot / upload-resources '
      'after release.',
    );
  }

  return ServerBaseline(
    snapshot: snapshot,
    snapshotMeta: snapshotMeta,
    resourceAssets: resourceAssets,
    resourceMeta: resourceMeta,
  );
}

Future<List<int>> _loadContentBytes({
  required String kind,
  required String id,
  required BaselineContentCache? cache,
  required bool forceRefresh,
  required Future<List<int>> Function() download,
  required void Function(List<int> bytes)? writeCache,
  required List<int>? Function()? readCache,
}) async {
  if (cache != null && !forceRefresh) {
    final cached = readCache!();
    if (cached != null) {
      stderr.writeln('==> Baseline $kind cache hit: $id');
      return cached;
    }
  }

  stderr.writeln(
    forceRefresh
        ? '==> Downloading baseline $kind (refresh): $id'
        : '==> Downloading baseline $kind: $id',
  );
  final bytes = await download();
  writeCache?.call(bytes);
  return bytes;
}
