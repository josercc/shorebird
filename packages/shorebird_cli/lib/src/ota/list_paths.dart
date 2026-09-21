// flutterpatch: ownership=OURS — from meta_ota
import 'dart:io';

import 'package:shorebird_cli/src/ota/ignore_rules.dart';

/// Log whether an ignore file was loaded (stderr).
void printIgnoreNotice(FlutterPatchIgnore ignore) {
  if (ignore.filePath != null) {
    final scope = ignore.platform != null
        ? ', platform=${ignore.platform}'
        : '';
    stderr.writeln(
      '==> Loaded ignore rules: ${ignore.filePath} '
      '(${ignore.ruleCount} rules$scope)',
    );
  } else {
    stderr.writeln(
      '==> No $flutterPatchIgnoreFileName '
      '(add one at the project root to exclude paths from comparison; '
      'use $flutterPatchSupportedResourcesFileName for hot-updatable '
      'extensions — unsupported suffixes are auto-ignored; '
      'use $flutterPatchUnsupportedResourcesFileName for path-level blocks; '
      '[android]/[ios] sections for platform-specific rules)',
    );
  }
}

/// Log supported-resources whitelist (stderr).
void printSupportedResourcesNotice(SupportedResourceExtensions supported) {
  if (supported.filePath != null) {
    stderr.writeln(
      '==> Loaded supported resource extensions: ${supported.filePath} '
      '(${supported.extensionCount} extensions)',
    );
  } else {
    stderr.writeln(
      '==> Using built-in supported resource extensions '
      '(${supported.extensionCount}: images/video/audio). '
      'Add $flutterPatchSupportedResourcesFileName to customize.',
    );
  }
}

/// Print one path per line to stdout.
void printPaths(Iterable<String> paths, {String? header}) {
  if (header != null) {
    stderr.writeln(header);
  }
  for (final path in paths) {
    stdout.writeln(path);
  }
}
