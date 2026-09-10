// flutterpatch: ownership=OURS — from meta_ota
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/ota/scan_assets.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';

/// Resolve local absolute path for a scanned Flutter asset under [appDir].
String? resolveAssetFilePath({
  required String appDir,
  required String package,
  required String assetPath,
  Map<String, String>? packageRoots,
}) {
  final roots = packageRoots ?? loadPackageRoots(appDir);
  final rootName = _rootPackageName(appDir);
  final root =
      roots[package] ??
      (package == rootName ? p.normalize(p.absolute(appDir)) : null);
  if (root == null) return null;
  final abs = p.normalize(p.join(root, assetPath));
  if (!File(abs).existsSync()) return null;
  return abs;
}

/// Upload add/update changed resources to the control plane ArtifactStore.
///
/// Same storage as patches (`obj/sha256/<hash>.bin`). Identical hashes are
/// skipped (server returns `created: false`). `remove` entries are unchanged.
Future<List<Map<String, Object?>>> uploadChangedResourcesToControl({
  required String appDir,
  required List<Map<String, Object?>> changes,
  required CodePushClient client,
  void Function(String message)? onLog,
}) async {
  Map<String, String>? roots;
  Map<String, String> rootsOrLoad() => roots ??= loadPackageRoots(appDir);

  final apiBase = client.hostedUri.toString().replaceAll(RegExp(r'/+$'), '');
  final out = <Map<String, Object?>>[];
  for (final raw in changes) {
    final entry = Map<String, Object?>.from(raw);
    final change = '${entry['change'] ?? ''}'.toLowerCase();
    if (change == 'remove') {
      out.add(entry);
      continue;
    }
    if (change != 'add' && change != 'update') {
      out.add(entry);
      continue;
    }

    // Already attached to control — skip re-upload.
    final existingPath = '${entry['artifact_path'] ?? ''}'.trim();
    final existingUrl = '${entry['download_url'] ?? ''}'.trim();
    if (existingPath.startsWith('obj/sha256/') ||
        (existingUrl.isNotEmpty && '${entry['storage'] ?? ''}' == 'control')) {
      out.add(entry);
      continue;
    }

    final package = '${entry['package'] ?? ''}';
    final path = '${entry['path'] ?? ''}';
    String? local;
    try {
      local = resolveAssetFilePath(
        appDir: appDir,
        package: package,
        assetPath: path,
        packageRoots: rootsOrLoad(),
      );
    } catch (e) {
      onLog?.call('Skip (cannot resolve package path): $package/$path ($e)');
      out.add(entry);
      continue;
    }
    if (local == null) {
      onLog?.call('Skip (local file missing): $package/$path');
      out.add(entry);
      continue;
    }

    final bytes = await File(local).readAsBytes();
    final fileHash = sha256.convert(bytes).toString();
    final listedHash = (entry['hash'] as String?)?.trim().toLowerCase() ?? '';
    if (listedHash.isNotEmpty && listedHash != fileHash) {
      onLog?.call(
        'Warning: manifest hash mismatch, using file hash: $package/$path',
      );
    }

    final existing = await client.getAssetMeta(fileHash);
    if (existing != null) {
      onLog?.call('Reuse asset: $package/$path (hash=$fileHash)');
      _attachControlMeta(entry, existing, apiBase);
      out.add(entry);
      continue;
    }

    onLog?.call('Upload asset: $package/$path');
    final uploaded = await client.uploadContentAddressedAsset(
      bytes: bytes,
      hash: fileHash,
    );
    _attachControlMeta(entry, uploaded, apiBase);
    final created = uploaded['created'] == true;
    onLog?.call(
      created
          ? '  → created ${uploaded['artifact_path']}'
          : '  → existed ${uploaded['artifact_path']}',
    );
    out.add(entry);
  }
  return out;
}

void _attachControlMeta(
  Map<String, Object?> entry,
  Map<String, dynamic> meta,
  String apiBase,
) {
  final hash = '${meta['hash'] ?? entry['hash'] ?? ''}';
  final artifactPath = '${meta['artifact_path'] ?? ''}';
  final downloadPath =
      '${meta['download_path'] ?? '/admin/v1/assets/$hash/content'}';
  entry['hash'] = hash;
  entry['artifact_path'] = artifactPath;
  entry['storage'] = 'control';
  entry['download_path'] = downloadPath;
  entry['download_url'] = '$apiBase$downloadPath';
  if (meta['size_bytes'] != null) {
    entry['size'] = (meta['size_bytes'] as num).toInt();
  }
}

String _rootPackageName(String appDir) {
  final pubspec = File(p.join(appDir, 'pubspec.yaml'));
  if (!pubspec.existsSync()) return p.basename(p.normalize(appDir));
  final match = RegExp(
    r'^name:\s*([^\s#]+)',
    multiLine: true,
  ).firstMatch(pubspec.readAsStringSync());
  return match?.group(1)?.trim() ?? p.basename(p.normalize(appDir));
}
