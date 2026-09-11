import 'package:mason_logger/mason_logger.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/config/config.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/ota/ota.dart';
import 'package:shorebird_cli/src/shorebird_command.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_validator.dart';

/// {@template check_ota_command}
/// `flutterpatch check-ota`
/// Scan Flutter / Android / iOS trees and compare against a baseline.
/// {@endtemplate}
class CheckOtaCommand extends ShorebirdCommand {
  /// {@macro check_ota_command}
  CheckOtaCommand() {
    argParser
      ..addOption(
        'flutter',
        help:
            'Flutter project directory (contains pubspec.yaml / lib). '
            'Overrides shorebird.yaml `flutter`. '
            'Default: cwd (or shorebird.yaml `flutter`).',
      )
      ..addOption(
        'app-dir',
        help: 'Same as --flutter (compatibility with other commands).',
      )
      ..addOption(
        'android',
        help:
            'Android project directory (optional). '
            'Overrides shorebird.yaml `android`. '
            'Default: <flutter>/android when present.',
      )
      ..addOption(
        'ios',
        help:
            'iOS project directory (optional). '
            'Overrides shorebird.yaml `ios`. '
            'Default: <flutter>/ios when present.',
      )
      ..addOption(
        'version',
        help:
            'Fetch server snapshot / resource config for this '
            'release_version as baseline.',
      )
      ..addOption(
        'out',
        abbr: 'o',
        help:
            'Snapshot output path '
            '(default: <flutter>/flutterpatch_snapshot.json).',
      )
      ..addOption(
        'baseline',
        help:
            'Local baseline snapshot path '
            '(alternative to --version; default: existing --out).',
      )
      ..addFlag(
        'write',
        defaultsTo: true,
        help: 'Write/update the local snapshot after scanning.',
      )
      ..addFlag(
        'include-dev',
        negatable: false,
        help: 'Also scan direct dev dependency packages.',
      )
      ..addFlag(
        'list-paths',
        negatable: false,
        help:
            'Print paths that would be included in the OTA snapshot '
            '(no write, no compare).',
      )
      ..addOption(
        'platform',
        allowed: ['android', 'ios'],
        help: 'Platform filter when fetching server baseline.',
      )
      ..addOption(
        'app-id',
        help: 'App id (default: shorebird.yaml app_id).',
      );
  }

  @override
  String get name => 'check-ota';

  @override
  String get description =>
      'Scan project trees and check whether changes are OTA-patchable.';

  @override
  Future<int> run() async {
    try {
      final yaml = shorebirdEnv.getShorebirdYaml();
      final dirs = resolveProjectDirs(
        flutterCli:
            (results['flutter'] as String?) ?? (results['app-dir'] as String?),
        androidCli: results['android'] as String?,
        iosCli: results['ios'] as String?,
        yaml: yaml,
      );
      final flutterPath = dirs.flutter;

      if (results['list-paths'] == true) {
        final ignore = FlutterPatchIgnore.load(flutterPath);
        final result = await checkOta(
          flutterDir: flutterPath,
          androidDir: dirs.android,
          iosDir: dirs.ios,
          writeSnapshot: false,
          skipLocalBaseline: true,
          includeDev: results['include-dev'] == true,
          ignore: ignore,
        );
        printIgnoreNotice(ignore);
        printPaths(
          result.snapshot.files.map((f) => f.path),
          header: '==> OTA snapshot paths (${result.snapshot.files.length})',
        );
        return ExitCode.success.code;
      }

      final versionOpt = (results['version'] as String?)?.trim();
      final version =
          (versionOpt != null && versionOpt.isNotEmpty) ? versionOpt : null;

      OtaSnapshot? serverSnapshot;
      var assetChanges = const <Map<String, Object?>>[];
      int? snapNumber;
      int? resNumber;
      String? releaseVersion;

      if (version != null) {
        try {
          await shorebirdValidator.validatePreconditions(
            checkUserIsAuthenticated: true,
          );
        } on PreconditionFailedException catch (e) {
          return e.exitCode.code;
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

        logger.info('==> Fetching server baseline: $version (app_id=$appId)');
        final baseline = await fetchServerBaseline(
          client: codePushClientWrapper.codePushClient,
          appId: appId,
          releaseVersion: version,
          platform: results['platform'] as String?,
        );
        serverSnapshot = baseline.snapshot;
        snapNumber = baseline.snapshotNumber;
        resNumber = baseline.resourceNumber;
        releaseVersion = version;

        if (baseline.resourceAssets.isNotEmpty) {
          final localAssets = await scanFlutterAssets(
            appDir: flutterPath,
            outPath: null,
            includeDev: results['include-dev'] == true,
            releaseVersion: version,
          );
          assetChanges = diffScannedAssets(
            baseline: baseline.resourceAssets,
            next: localAssets.resources,
          );
        }

        if (serverSnapshot == null && results['baseline'] == null) {
          logger.info(
            'Note: no server snapshot; falling back to local baseline if any.',
          );
        }
      }

      final result = await checkOta(
        flutterDir: flutterPath,
        androidDir: dirs.android,
        iosDir: dirs.ios,
        outPath: results['out'] as String?,
        baselinePath: results['baseline'] as String?,
        baselineSnapshot: serverSnapshot,
        baselineSourceLabel: serverSnapshot != null ? 'server' : null,
        releaseVersion: releaseVersion,
        serverSnapshotNumber: snapNumber,
        serverResourceNumber: resNumber,
        assetChanges: assetChanges,
        writeSnapshot: results['write'] != false,
        skipLocalBaseline: serverSnapshot != null,
        includeDev: results['include-dev'] == true,
      );

      if (isJsonMode) {
        emitJsonSuccess(result.toJson());
      } else {
        printCheckOtaReport(result);
      }

      // 2 = OTA patch not applicable (no baseline / no changes / blocked).
      if (!result.otaSupported) {
        return 2;
      }
      return ExitCode.success.code;
    } on Exception catch (error) {
      logger.err('$error');
      return ExitCode.software.code;
    }
  }
}
