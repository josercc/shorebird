import 'package:mason_logger/mason_logger.dart';
import 'package:shorebird_cli/src/auth/auth.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/shorebird_command.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';

/// {@template account_login_command}
/// `flutterpatch account login`
///
/// Saves an API token for the current `shorebird.yaml` → `base_url` in the
/// local credentials file. [shorebirdTokenEnvVar] still takes priority when
/// set.
/// {@endtemplate}
class AccountLoginCommand extends ShorebirdCommand {
  /// {@macro account_login_command}
  AccountLoginCommand() {
    argParser.addOption(
      'token',
      help:
          'API token to save for the current base_url. '
          'If omitted, you will be prompted.',
    );
  }

  @override
  String get name => 'login';

  @override
  String get description =>
      'Save an API token for the current shorebird.yaml base_url.\n\n'
      'Token resolution order for other commands:\n'
      '  1. $shorebirdTokenEnvVar environment variable\n'
      '  2. Local credentials for base_url\n'
      '  3. Error\n';

  @override
  Future<int> run() async {
    final hostedUri = shorebirdEnv.hostedUri;
    if (hostedUri == null) {
      logger.err(
        'Missing base_url in shorebird.yaml. '
        'Run flutterpatch init or set base_url before logging in.',
      );
      return ExitCode.config.code;
    }

    var token = results['token'] as String?;
    if (token == null || token.trim().isEmpty) {
      if (!shorebirdEnv.canAcceptUserInput) {
        logger.err(
          'Missing --token. Pass --token=<token> in non-interactive mode.',
        );
        return ExitCode.usage.code;
      }
      token = logger.prompt(
        '${lightGreen.wrap('?')} API token for ${normalizeAuthUrl(hostedUri)}:',
      );
    }

    try {
      auth.saveToken(token);
    } on Exception catch (error) {
      logger.err('$error');
      return ExitCode.software.code;
    }

    logger.info(
      '''
${lightGreen.wrap('Logged in.')}
Saved token for ${lightCyan.wrap(normalizeAuthUrl(hostedUri))}
Credentials: ${auth.credentialsFilePath}

Tip: ${lightCyan.wrap(shorebirdTokenEnvVar)} overrides this local token when set.
''',
    );
    return ExitCode.success.code;
  }
}
