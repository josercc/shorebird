import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/config/shorebird_yaml.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';

/// Resolved Flutter / Android / iOS project directories for OTA scans.
class ProjectDirs {
  /// Creates resolved project directories.
  const ProjectDirs({
    required this.flutter,
    this.android,
    this.ios,
  });

  /// Flutter project root (contains `pubspec.yaml` / `lib`).
  final String flutter;

  /// Android project root, if configured or discovered.
  final String? android;

  /// iOS project root, if configured or discovered.
  final String? ios;
}

/// Resolves project directories for OTA snapshot / resource scans.
///
/// Precedence for each path:
/// 1. Explicit CLI option ([flutterCli] / [androidCli] / [iosCli])
/// 2. Matching field in [yaml] (paths relative to the `shorebird.yaml`
///    directory, or absolute)
/// 3. Defaults:
///    - flutter → [cwd] (where `flutterpatch` was invoked)
///    - android → `<flutter>/android` when that directory exists
///    - ios → `<flutter>/ios` when that directory exists
ProjectDirs resolveProjectDirs({
  String? flutterCli,
  String? androidCli,
  String? iosCli,
  ShorebirdYaml? yaml,
  Directory? yamlRoot,
  Directory? cwd,
}) {
  final workingDir = cwd ?? Directory.current;
  final configRoot =
      yamlRoot ?? shorebirdEnv.getShorebirdProjectRoot() ?? workingDir;

  final flutter = _resolvePath(
    cli: flutterCli,
    fromYaml: yaml?.flutter,
    configRoot: configRoot,
    fallback: workingDir.path,
  );

  final android = _resolveOptionalPath(
    cli: androidCli,
    fromYaml: yaml?.android,
    configRoot: configRoot,
    discovered: Directory(p.join(flutter, 'android')),
  );

  final ios = _resolveOptionalPath(
    cli: iosCli,
    fromYaml: yaml?.ios,
    configRoot: configRoot,
    discovered: Directory(p.join(flutter, 'ios')),
  );

  return ProjectDirs(flutter: flutter, android: android, ios: ios);
}

String _resolvePath({
  required String? cli,
  required String? fromYaml,
  required Directory configRoot,
  required String fallback,
}) {
  final fromCli = _normalizeNonEmpty(cli);
  if (fromCli != null) return p.normalize(p.absolute(fromCli));

  final yamlPath = _normalizeNonEmpty(fromYaml);
  if (yamlPath != null) {
    return p.isAbsolute(yamlPath)
        ? p.normalize(yamlPath)
        : p.normalize(p.absolute(p.join(configRoot.path, yamlPath)));
  }

  return p.normalize(p.absolute(fallback));
}

String? _resolveOptionalPath({
  required String? cli,
  required String? fromYaml,
  required Directory configRoot,
  required Directory discovered,
}) {
  final fromCli = _normalizeNonEmpty(cli);
  if (fromCli != null) return p.normalize(p.absolute(fromCli));

  final yamlPath = _normalizeNonEmpty(fromYaml);
  if (yamlPath != null) {
    return p.isAbsolute(yamlPath)
        ? p.normalize(yamlPath)
        : p.normalize(p.absolute(p.join(configRoot.path, yamlPath)));
  }

  if (discovered.existsSync()) {
    return p.normalize(p.absolute(discovered.path));
  }
  return null;
}

String? _normalizeNonEmpty(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return trimmed;
}
