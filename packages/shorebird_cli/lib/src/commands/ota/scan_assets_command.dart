import 'package:mason_logger/mason_logger.dart';
import 'package:shorebird_cli/src/config/config.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/ota/ota.dart';
import 'package:shorebird_cli/src/shorebird_command.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';

/// {@template scan_assets_command}
/// `flutterpatch scan-assets`
/// Scan Flutter assets (app + dependency packages) and write a resource JSON.
/// {@endtemplate}
class ScanAssetsCommand extends ShorebirdCommand {
  /// {@macro scan_assets_command}
  ScanAssetsCommand() {
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
        'version',
        help: 'Optional release_version written into the output JSON.',
      )
      ..addOption(
        'out',
        abbr: 'o',
        help:
            'Output JSON path '
            '(default: <flutter>/flutterpatch_assets.json).',
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
            'Print paths that would be included (no JSON write). '
            'Useful with .flutterpatchignore.',
      );
  }

  @override
  String get name => 'scan-assets';

  @override
  String get description =>
      'Scan Flutter assets and write a resource inventory JSON.';

  @override
  Future<int> run() async {
    final dirs = resolveProjectDirs(
      flutterCli:
          (results['flutter'] as String?) ?? (results['app-dir'] as String?),
      yaml: shorebirdEnv.getShorebirdYaml(),
    );
    final appDir = dirs.flutter;
    final listOnly = results['list-paths'] == true;

    try {
      final ignore = FlutterPatchIgnore.load(appDir);
      final result = await scanFlutterAssets(
        appDir: appDir,
        outPath: results['out'] as String?,
        includeDev: results['include-dev'] == true,
        releaseVersion: results['version'] as String?,
        writeConfig: !listOnly,
        ignore: ignore,
      );

      if (listOnly) {
        printIgnoreNotice(ignore);
        String? rootName;
        for (final pkg in listScannablePackages(
          appDir: appDir,
          includeDev: results['include-dev'] == true,
        )) {
          if (pkg.isRoot) {
            rootName = pkg.name;
            break;
          }
        }
        printPaths([
          for (final r in result.resources)
            (rootName != null && r.package == rootName)
                ? r.path
                : 'package:${r.package}/${r.path}',
        ], header: '==> Asset paths (${result.resources.length})');
      } else {
        logger.info(
          '==> Scanned ${result.resources.length} assets → ${result.outPath}',
        );
      }
      return ExitCode.success.code;
    } on Exception catch (error) {
      logger.err('$error');
      return ExitCode.software.code;
    }
  }
}
