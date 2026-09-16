// flutterpatch: ownership=OURS — from meta_ota
import 'dart:io';

import 'package:shorebird_cli/src/ota/ignore_rules.dart';

/// Log whether an ignore file was loaded (stderr).
void printIgnoreNotice(FlutterPatchIgnore ignore) {
  if (ignore.filePath != null) {
    final scope = ignore.platform != null ? ', platform=${ignore.platform}' : '';
    stderr.writeln(
      '==> Loaded ignore rules: ${ignore.filePath} '
      '(${ignore.ruleCount} rules$scope)',
    );
  } else {
    stderr.writeln(
      '==> No $flutterPatchIgnoreFileName '
      '(add one at the project root to exclude paths from comparison; '
      'use $flutterPatchUnsupportedResourcesFileName for fonts etc. that cannot '
      'be hot-updated if they change; '
      '[android]/[ios] sections for platform-specific rules)',
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
