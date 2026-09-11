import 'package:mason_logger/mason_logger.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/config/config.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/ota/ota.dart';
import 'package:shorebird_cli/src/shorebird_command.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_validator.dart';

/// {@template upload_resources_command}
/// `flutterpatch upload-resources`
/// Scan (optional) and upload a release resource config to the control plane.
/// {@endtemplate}
class UploadResourcesCommand extends ShorebirdCommand {
  /// {@macro upload_resources_command}
  UploadResourcesCommand() {
    argParser
      ..addOption(
        'flutter',
        help:
            'Flutter project directory. Overrides shorebird.yaml `flutter`. '
            'Default: cwd (or shorebird.yaml `flutter`).',
      )
      ..addOption(
        'app-dir',
        help: 'Same as --flutter.',
      )
      ..addOption(
        'app-id',
        help: 'App id (default: shorebird.yaml app_id).',
      )
      ..addOption(
        'version',
        help: 'release_version (default: pubspec.yaml version).',
      )
      ..addOption(
        'config',
        abbr: 'c',
        help: 'Existing resource JSON; default rescans then uploads.',
      )
      ..addOption('notes', help: 'Optional notes stored with the snapshot.')
      ..addOption('channel', defaultsTo: 'stable')
      ..addFlag(
        'rescan',
        defaultsTo: true,
        help: 'Rescan before upload (--no-rescan uses --config as-is).',
      )
      ..addFlag(
        'include-dev',
        negatable: false,
        help: 'Include direct dev dependency assets when scanning.',
      )
      ..addOption(
        'platform',
        allowed: ['android', 'ios'],
        help: 'Platform tag for the uploaded resource snapshot.',
      );
  }

  @override
  String get name => 'upload-resources';

  @override
  String get description =>
      'Upload a Flutter asset resource inventory for a release version.';

  @override
  Future<int> run() async {
    try {
      await shorebirdValidator.validatePreconditions(
        checkUserIsAuthenticated: true,
      );
    } on PreconditionFailedException catch (e) {
      return e.exitCode.code;
    }

    final yaml = shorebirdEnv.getShorebirdYaml();
    final dirs = resolveProjectDirs(
      flutterCli:
          (results['flutter'] as String?) ?? (results['app-dir'] as String?),
      yaml: yaml,
    );

    final versionOpt = (results['version'] as String?)?.trim();
    final version = (versionOpt != null && versionOpt.isNotEmpty)
        ? versionOpt
        : readPubspecVersion(dirs.flutter);
    if (version == null || version.isEmpty) {
      logger.err(
        'upload-resources requires --version '
        '(or a version field in pubspec.yaml).',
      );
      return ExitCode.usage.code;
    }

    final explicitAppId = (results['app-id'] as String?)?.trim();
    final appId = (explicitAppId != null && explicitAppId.isNotEmpty)
        ? explicitAppId
        : yaml?.appId;
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
      await uploadReleaseResources(
        ResourceUploadOptions(
          appDir: dirs.flutter,
          releaseVersion: version,
          client: codePushClientWrapper.codePushClient,
          appId: appId,
          configPath: results['config'] as String?,
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
