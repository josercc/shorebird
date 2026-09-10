// flutterpatch: ownership=OURS — from meta_ota
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/ota/check_ota.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';

/// Options for uploading a release OTA eligibility snapshot.
class SnapshotUploadOptions {
  SnapshotUploadOptions({
    required this.flutterDir,
    required this.releaseVersion,
    required this.client,
    required this.appId,
    this.androidDir,
    this.iosDir,
    this.snapshotPath,
    this.notes,
    this.channel = 'stable',
    this.rescan = true,
    this.includeDev = false,
    this.platform,
  });

  final String flutterDir;
  final String releaseVersion;
  final CodePushClient client;
  final String appId;
  final String? androidDir;
  final String? iosDir;
  final String? snapshotPath;
  final String? notes;
  final String channel;
  final bool rescan;
  final bool includeDev;
  final String? platform;
}

/// Scan (optional) then upload the version OTA snapshot to the control plane.
Future<Map<String, dynamic>> uploadReleaseSnapshot(
  SnapshotUploadOptions opts,
) async {
  String snapshotFile;
  if (opts.rescan ||
      opts.snapshotPath == null ||
      !File(opts.snapshotPath!).existsSync()) {
    final scanned = await checkOta(
      flutterDir: opts.flutterDir,
      androidDir: opts.androidDir,
      iosDir: opts.iosDir,
      outPath: opts.snapshotPath,
      writeSnapshot: true,
      // Upload uses current tree as the release baseline — no local compare.
      skipLocalBaseline: true,
      includeDev: opts.includeDev,
    );
    snapshotFile = scanned.outPath;
    stdout.writeln(
      '==> Scanned snapshot: ${scanned.snapshot.files.length} files → '
      '$snapshotFile',
    );
  } else {
    snapshotFile = p.normalize(p.absolute(opts.snapshotPath!));
  }

  final bytes = await File(snapshotFile).readAsBytes();
  final hash = sha256.convert(bytes).toString();
  final decoded = jsonDecode(utf8.decode(bytes));
  final fileCount = decoded is Map && decoded['files'] is List
      ? (decoded['files'] as List).length
      : null;

  stdout.writeln('==> app_id: ${opts.appId}');
  stdout.writeln('==> release_version: ${opts.releaseVersion}');
  if (opts.platform != null) {
    stdout.writeln('==> platform: ${opts.platform}');
  }
  stdout.writeln(
    '==> snapshot: $snapshotFile (${bytes.length} bytes, hash=$hash)',
  );

  final created = await opts.client.uploadOtaSnapshot(
    appId: opts.appId,
    releaseVersion: opts.releaseVersion,
    contentBytes: bytes,
    platform: opts.platform,
    channel: opts.channel,
    notes: opts.notes,
    fileCount: fileCount,
  );
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(created));
  stdout.writeln(
    '==> Uploaded OTA snapshot #${created['number']} '
    '(${created['file_count'] ?? fileCount ?? '?'} files)',
  );
  return created;
}
