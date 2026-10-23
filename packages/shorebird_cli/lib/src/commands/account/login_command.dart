import 'package:mason_logger/mason_logger.dart';
import 'package:shorebird_cli/src/auth/auth.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/shorebird_command.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';

/// {@template account_login_command}
/// `flutterpatch account login`
///
/// Saves an API token for a control API `base_url` in the local credentials
/// file. The URL is taken from `--base-url`, `shorebird.yaml`, or an
/// interactive prompt — so login works before `flutterpatch init`.
/// [shorebirdTokenEnvVar] still takes priority when set.
/// {@endtemplate}
class AccountLoginCommand extends ShorebirdCommand {
  /// {@macro account_login_command}
  AccountLoginCommand() {
    argParser
      ..addOption(
        'base-url',
        help:
            'FlutterPatch control_api base URL to save the token for '
            '(e.g. http://127.0.0.1:8080). '
            'Defaults to shorebird.yaml → base_url when present; '
            'otherwise you will be prompted.',
      )
      ..addOption(
        'token',
        help:
            'API token to save for the base_url. '
            'If omitted, you will be prompted.',
      );
  }

  @override
  String get name => 'login';

  @override
  String get description =>
      'Save an API token for a control API base_url.\n\n'
      'Does not require shorebird.yaml — useful before '
      '`flutterpatch init`.\n\n'
      'Token resolution order for other commands:\n'
      '  1. $shorebirdTokenEnvVar environment variable\n'
      '  2. Local credentials for base_url\n'
      '  3. Error\n';

  @override
  Future<int> run() async {
    final hostedUri = _resolveHostedUri();
    if (hostedUri == null) {
      return ExitCode.usage.code;
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
      auth.saveToken(token, url: hostedUri);
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
Next: run ${lightCyan.wrap('flutterpatch init')} if this project is not initialized yet.
''',
    );
    return ExitCode.success.code;
  }

  /// Resolves control API URL from `--base-url`, `shorebird.yaml`, or prompt.
  Uri? _resolveHostedUri() {
    final fromArg = (results['base-url'] as String?)?.trim();
    if (fromArg != null && fromArg.isNotEmpty) {
      final uri = Uri.tryParse(fromArg);
      if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
        logger.err('Invalid base URL: $fromArg');
        return null;
      }
      return uri;
    }

    final fromYaml = shorebirdEnv.hostedUri;
    if (fromYaml != null) {
      return fromYaml;
    }

    if (!shorebirdEnv.canAcceptUserInput) {
      logger.err(
        'Missing base_url. Pass --base-url=<url> in non-interactive mode '
        '(no shorebird.yaml required), e.g. '
        '--base-url=http://127.0.0.1:8080.',
      );
      return null;
    }

    final prompted = logger.prompt(
      '${lightGreen.wrap('?')} FlutterPatch control_api base URL '
      '(e.g. http://127.0.0.1:8080):',
    ).trim();
    if (prompted.isEmpty) {
      logger.err('Base URL is required.');
      return null;
    }
    final uri = Uri.tryParse(prompted);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      logger.err('Invalid base URL: $prompted');
      return null;
    }
    return uri;
  }
}
