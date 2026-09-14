import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/commands/flutter/flutter_revision_arg.dart';
import 'package:shorebird_cli/src/json_output.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/shorebird_cli_command_runner.dart';
import 'package:shorebird_cli/src/shorebird_command.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_flutter.dart';

/// {@template flutter_install_command}
/// `flutterpatch flutter install <version>`
/// Install a Shorebird Flutter SDK revision and precache platform resources.
/// {@endtemplate}
class FlutterInstallCommand extends ShorebirdCommand with FlutterRevisionArg {
  /// {@macro flutter_install_command}
  FlutterInstallCommand();

  @override
  String get description =>
      'Install a Shorebird Flutter SDK version and its platform resources.';

  @override
  String get name => 'install';

  @override
  String get invocation =>
      '${runner?.executableName ?? executableName} flutter install <version>';

  @override
  Future<int> run() async {
    final versionArg = versionArgument;
    if (versionArg == null) {
      return missingVersionExit(commandName: name);
    }

    final resolved = await resolveRevision(versionArg);
    final revision = resolved.revision;
    if (revision == null) return resolved.exitCode;

    try {
      await shorebirdFlutter.installRevision(revision: revision);
    } on Exception catch (error) {
      final message = 'Failed to install Flutter $versionArg: $error';
      if (isJsonMode) {
        emitJsonError(code: JsonErrorCode.softwareError, message: message);
      } else {
        logger.err(message);
      }
      return ExitCode.software.code;
    }

    final versionLabel =
        await shorebirdFlutter.getVersionForRevision(
          flutterRevision: revision,
        ) ??
        versionArg;

    if (isJsonMode) {
      emitJsonSuccess({
        'version': versionLabel,
        'revision': revision,
        'path': p.join(
          shorebirdEnv.shorebirdRoot.path,
          'bin',
          'cache',
          'flutter',
          revision,
        ),
      });
      return ExitCode.success.code;
    }

    logger.info(
      '''
${lightGreen.wrap('Installed Flutter $versionLabel')}
Revision: ${lightCyan.wrap(revision)}
''',
    );
    return ExitCode.success.code;
  }
}
