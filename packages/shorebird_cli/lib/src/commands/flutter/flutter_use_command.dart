import 'package:mason_logger/mason_logger.dart';
import 'package:shorebird_cli/src/commands/flutter/flutter_revision_arg.dart';
import 'package:shorebird_cli/src/json_output.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/shorebird_cli_command_runner.dart';
import 'package:shorebird_cli/src/shorebird_command.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_flutter.dart';

/// {@template flutter_use_command}
/// `flutterpatch flutter use <version>`
/// Install (if needed) and set a Shorebird Flutter SDK revision as the default.
/// {@endtemplate}
class FlutterUseCommand extends ShorebirdCommand with FlutterRevisionArg {
  /// {@macro flutter_use_command}
  FlutterUseCommand();

  @override
  String get description =>
      'Set the default Shorebird Flutter SDK version '
      '(installs it if missing).';

  @override
  String get name => 'use';

  @override
  String get invocation =>
      '${runner?.executableName ?? executableName} flutter use <version>';

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

    try {
      shorebirdEnv.setFlutterRevision(revision);
    } on Exception catch (error) {
      final message = 'Failed to set default Flutter version: $error';
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
        'path': shorebirdEnv.flutterDirectory.path,
      });
      return ExitCode.success.code;
    }

    logger.info(
      '''
${lightGreen.wrap('Now using Flutter $versionLabel')}
Revision: ${lightCyan.wrap(revision)}
''',
    );
    return ExitCode.success.code;
  }
}
