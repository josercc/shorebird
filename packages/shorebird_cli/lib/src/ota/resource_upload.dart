// flutterpatch: ownership=OURS — from meta_ota
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/ota/scan_assets.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';

/// Options for uploading a release resource snapshot.
class ResourceUploadOptions {
  ResourceUploadOptions({
    required this.appDir,
    required this.releaseVersion,
    required this.client,
    required this.appId,
    this.configPath,
    this.notes,
    this.channel = 'stable',
    this.rescan = true,
    this.includeDev = false,
    this.platform,
  });

  final String appDir;
  final String releaseVersion;
  final CodePushClient client;
  final String appId;
  final String? configPath;
  final String? notes;
  final String channel;
  final bool rescan;
  final bool includeDev;
  final String? platform;
}

/// Scan (optional) then upload the version resource config to the control plane.
Future<Map<String, dynamic>> uploadReleaseResources(
  ResourceUploadOptions opts,
) async {
  String configFile;
  if (opts.rescan ||
      opts.configPath == null ||
      !File(opts.configPath!).existsSync()) {
    final scanned = await scanFlutterAssets(
      appDir: opts.appDir,
      outPath: opts.configPath,
      includeDev: opts.includeDev,
      releaseVersion: opts.releaseVersion,
    );
    configFile = scanned.outPath;
    stdout.writeln(
      '==> Scanned assets: ${scanned.resources.length} → $configFile',
    );
  } else {
    configFile = p.normalize(p.absolute(opts.configPath!));
    await _ensureReleaseVersionInConfig(configFile, opts.releaseVersion);
  }

  final bytes = await File(configFile).readAsBytes();
  final hash = sha256.convert(bytes).toString();
  final decoded = jsonDecode(utf8.decode(bytes));
  final count = decoded is Map && decoded['resources'] is List
      ? (decoded['resources'] as List).length
      : null;

  stdout.writeln('==> app_id: ${opts.appId}');
  stdout.writeln('==> release_version: ${opts.releaseVersion}');
  if (opts.platform != null) {
    stdout.writeln('==> platform: ${opts.platform}');
  }
  stdout.writeln('==> config: $configFile (${bytes.length} bytes, hash=$hash)');

  final created = await opts.client.uploadResourceSnapshot(
    appId: opts.appId,
    releaseVersion: opts.releaseVersion,
    contentBytes: bytes,
    platform: opts.platform,
    channel: opts.channel,
    notes: opts.notes,
    resourceCount: count,
  );
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(created));
  stdout.writeln(
    '==> Uploaded resource snapshot #${created['number']} '
    '(${created['resource_count'] ?? count ?? '?'} resources)',
  );
  return created;
}

Future<void> _ensureReleaseVersionInConfig(
  String path,
  String releaseVersion,
) async {
  final file = File(path);
  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! Map) return;
  final map = Map<String, dynamic>.from(decoded);
  if (map['release_version'] == releaseVersion) return;
  map['release_version'] = releaseVersion;
  await file.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(map)}\n',
  );
}
