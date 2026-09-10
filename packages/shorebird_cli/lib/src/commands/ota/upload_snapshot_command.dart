import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/ota/ota.dart';
import 'package:shorebird_cli/src/shorebird_command.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_validator.dart';

/// {@template upload_snapshot_command}
/// `flutterpatch upload-snapshot`
/// Scan (optional) and upload an OTA eligibility snapshot for a release.
/// {@endtemplate}
class UploadSnapshotCommand extends ShorebirdCommand {
  /// {@macro upload_snapshot_command}
  UploadSnapshotCommand() {
    argParser
      ..addOption(
        'flutter',
        help: 'Flutter project directory.',
      )
      ..addOption(
        'app-dir',
        help: 'Same as --flutter.',
        defaultsTo: Directory.current.path,
      )
      ..addOption('android', help: 'Android project directory (optional).')
      ..addOption('ios', help: 'iOS project directory (optional).')
      ..addOption(
        'app-id',
        help: 'App id (default: shorebird.yaml app_id).',
      )
      ..addOption(
        'version',
        help: 'release_version (default: pubspec.yaml version).',
      )
      ..addOption(
        'snapshot',
        abbr: 'c',
        help: 'Existing snapshot JSON; default rescans then uploads.',
      )
      ..addOption('notes', help: 'Optional notes stored with the snapshot.')
      ..addOption('channel', defaultsTo: 'stable')
      ..addFlag(
        'rescan',
        defaultsTo: true,
        help: 'Rescan before upload (--no-rescan uses --snapshot as-is).',
      )
      ..addFlag(
        'include-dev',
        negatable: false,
        help: 'Include direct dev dependency packages when scanning.',
      )
      ..addOption(
        'platform',
        allowed: ['android', 'ios'],
        help: 'Platform tag for the uploaded OTA snapshot.',
      );
  }

  @override
  String get name => 'upload-snapshot';

  @override
  String get description =>
      'Upload an OTA eligibility snapshot for a release version.';

  @override
  Future<int> run() async {
    try {
      await shorebirdValidator.validatePreconditions(
        checkUserIsAuthenticated: true,
      );
    } on PreconditionFailedException catch (e) {
      return e.exitCode.code;
    }

    final flutterPath = p.normalize(
      p.absolute(
        (results['flutter'] as String?) ??
            (results['app-dir'] as String?) ??
            Directory.current.path,
      ),
    );

    final versionOpt = (results['version'] as String?)?.trim();
    final version = (versionOpt != null && versionOpt.isNotEmpty)
        ? versionOpt
        : readPubspecVersion(flutterPath);
    if (version == null || version.isEmpty) {
      logger.err(
        'upload-snapshot requires --version '
        '(or a version field in pubspec.yaml).',
      );
      return ExitCode.usage.code;
    }

    final explicitAppId = (results['app-id'] as String?)?.trim();
    final appId = (explicitAppId != null && explicitAppId.isNotEmpty)
        ? explicitAppId
        : shorebirdEnv.getShorebirdYaml()?.appId;
    if (appId == null || appId.isEmpty) {
      logger.err(
        'Missing app_id. Pass --app-id or run from a project with '
        'shorebird.yaml.',
      );
      return ExitCode.software.code;
    }

    if (shorebirdEnv.hostedUri == null) {
      logger.err(
        'Missing control API base URL. Set base_url in shorebird.yaml '
        '(e.g. via `flutterpatch init --base-url …`).',
      );
      return ExitCode.config.code;
    }

    try {
      await uploadReleaseSnapshot(
        SnapshotUploadOptions(
          flutterDir: flutterPath,
          androidDir: results['android'] as String?,
          iosDir: results['ios'] as String?,
          releaseVersion: version,
          client: codePushClientWrapper.codePushClient,
          appId: appId,
          snapshotPath: results['snapshot'] as String?,
          notes: results['notes'] as String?,
          channel: results['channel'] as String? ?? 'stable',
          rescan: results['rescan'] != false,
          includeDev: results['include-dev'] == true,
          platform: results['platform'] as String?,
        ),
      );
      return ExitCode.success.code;
    } on Exception catch (error) {
      logger.err('$error');
      return ExitCode.software.code;
    }
  }
}
