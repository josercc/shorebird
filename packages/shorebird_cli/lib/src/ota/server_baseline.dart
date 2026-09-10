// flutterpatch: ownership=OURS — from meta_ota
import 'dart:convert';
import 'dart:io';

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

/// Fetch latest published snapshot + resource config for [releaseVersion].
Future<ServerBaseline> fetchServerBaseline({
  required CodePushClient client,
  required String appId,
  required String releaseVersion,
  String? platform,
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
    final bytes = await client.getOtaSnapshotContent(id);
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
    final bytes = await client.getResourceSnapshotContent(id);
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
