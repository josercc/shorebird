import 'dart:io';

import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_version.dart';
import 'package:shorebird_cli/src/validators/validators.dart';

/// Verifies that the currently installed version of Shorebird is the latest.
class ShorebirdVersionValidator extends Validator {
  /// Creates a new [ShorebirdVersionValidator].
  ShorebirdVersionValidator();

  @override
  String get description => 'FlutterPatch is up-to-date';

  @override
  Future<List<ValidationIssue>> validate() async {
    // Packaged website installs have no git remote; skip upgrade checks.
    if (!shorebirdEnv.isGitInstall) {
      return const [];
    }

    final bool isShorebirdUpToDate;

    try {
      isShorebirdUpToDate = await shorebirdVersion.isLatest();
    } on ProcessException catch (e) {
      return [
        ValidationIssue(
          severity: ValidationIssueSeverity.error,
          message: 'Failed to get FlutterPatch version. Error: ${e.message}',
        ),
      ];
    }

    if (!isShorebirdUpToDate) {
      return [
        const ValidationIssue(
          severity: ValidationIssueSeverity.warning,
          message: '''
A new version of FlutterPatch is available! Run `flutterpatch upgrade` to upgrade.''',
        ),
      ];
    }

    return [];
  }
}
