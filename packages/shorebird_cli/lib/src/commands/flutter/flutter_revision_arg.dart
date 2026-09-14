import 'package:mason_logger/mason_logger.dart';
import 'package:shorebird_cli/src/json_output.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/shorebird_command.dart';
import 'package:shorebird_cli/src/shorebird_flutter.dart';

/// Shared helpers for Flutter commands that take a version/revision argument.
mixin FlutterRevisionArg on ShorebirdCommand {
  /// The version or git revision from the first positional argument.
  String? get versionArgument {
    if (results.rest.isEmpty) return null;
    return results.rest.first;
  }

  /// Resolves [versionArg] to a Flutter git revision.
  ///
  /// Returns the revision on success, or `null` after emitting an error
  /// (JSON or human) and leaving the caller to return the exit code.
  Future<({String? revision, int exitCode})> resolveRevision(
    String versionArg,
  ) async {
    try {
      await shorebirdFlutter.ensureDefaultFlutterInstalled();
    } on Exception catch (error) {
      final message = 'Failed to install the default Flutter SDK.\n$error';
      if (isJsonMode) {
        emitJsonError(code: JsonErrorCode.softwareError, message: message);
      } else {
        logger.err(message);
      }
      return (revision: null, exitCode: ExitCode.software.code);
    }

    await shorebirdFlutter.fetchRemoteRefs();

    final String? revision;
    try {
      revision = await shorebirdFlutter.resolveFlutterRevision(versionArg);
    } on Exception catch (error) {
      final message =
          'Unable to determine revision for Flutter version: $versionArg.\n'
          '$error';
      if (isJsonMode) {
        emitJsonError(code: JsonErrorCode.softwareError, message: message);
      } else {
        logger.err(message);
      }
      return (revision: null, exitCode: ExitCode.software.code);
    }

    if (revision == null) {
      final message =
          'Version $versionArg not found. '
          'Use `flutterpatch flutter versions list` to list available '
          'versions.';
      if (isJsonMode) {
        emitJsonError(
          code: JsonErrorCode.usageError,
          message: message,
          hint: 'Pass a Flutter semver (e.g. 3.27.4) or git hash.',
        );
      } else {
        logger.err(message);
      }
      return (revision: null, exitCode: ExitCode.software.code);
    }

    return (revision: revision, exitCode: ExitCode.success.code);
  }

  /// Reports a missing required version argument and returns [ExitCode.usage].
  int missingVersionExit({required String commandName}) {
    const message = 'Missing required version argument.';
    final hint =
        'Usage: flutterpatch flutter $commandName <version>\n'
        'Example: flutterpatch flutter $commandName 3.27.4';
    if (isJsonMode) {
      emitJsonError(
        code: JsonErrorCode.usageError,
        message: message,
        hint: hint,
      );
    } else {
      logger.err('$message\n$hint');
    }
    return ExitCode.usage.code;
  }
}
