// flutterpatch: ownership=OURS — from meta_ota
import 'dart:io';

import 'package:path/path.dart' as p;

/// Read `version: x.y.z+build` from the app [pubspec.yaml].
///
/// Returns null when the file or field is missing.
String? readPubspecVersion(String appDir) {
  final file = File(p.join(appDir, 'pubspec.yaml'));
  if (!file.existsSync()) return null;
  final match = RegExp(
    r'^version:\s*([^\s#]+)',
    multiLine: true,
  ).firstMatch(file.readAsStringSync());
  final version = match?.group(1)?.trim();
  if (version == null || version.isEmpty) return null;
  return version;
}
