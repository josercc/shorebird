import 'package:mason_logger/mason_logger.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/ota/ota.dart';
import 'package:shorebird_cli/src/shorebird_command.dart';

/// {@template diff_command}
/// `flutterpatch diff`
/// Create a local binary diff between two artifacts.
/// {@endtemplate}
class DiffCommand extends ShorebirdCommand {
  /// {@macro diff_command}
  DiffCommand() {
    argParser
      ..addOption('base', mandatory: true, help: 'Baseline artifact path.')
      ..addOption('next', mandatory: true, help: 'Next artifact path.')
      ..addOption('out', mandatory: true, help: 'Output patch path.')
      ..addFlag(
        'bsdiff',
        defaultsTo: true,
        help: 'Prefer bsdiff when available on PATH.',
      );
  }

  @override
  String get name => 'diff';

  @override
  String get description =>
      'Create a local binary diff (bsdiff if available, else full copy).';

  @override
  Future<int> run() async {
    try {
      await createDiff(
        basePath: results['base'] as String,
        nextPath: results['next'] as String,
        outPath: results['out'] as String,
        preferBsdiff: results['bsdiff'] != false,
      );
      return ExitCode.success.code;
    } on Exception catch (error) {
      logger.err('$error');
      return ExitCode.software.code;
    }
  }
}
