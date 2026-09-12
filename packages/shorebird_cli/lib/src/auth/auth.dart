// flutterpatch: ownership=REPLACE — auth via FLUTTERPATCH_TOKEN or local URL map
import 'dart:convert';
import 'dart:io';

import 'package:cli_util/cli_util.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/http_client/http_client.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_cli/src/shorebird_cli_command_runner.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';

export 'ci_token.dart';

/// A reference to an [Auth] instance.
final authRef = create(Auth.new);

/// The [Auth] instance available in the current zone.
Auth get auth => read(authRef);

/// The environment variable that holds the FlutterPatch admin/API token.
const shorebirdTokenEnvVar = 'FLUTTERPATCH_TOKEN';

/// Normalizes a control-API URL for credentials lookup (strip trailing `/`).
String normalizeAuthUrl(Uri uri) {
  return uri.toString().replaceAll(RegExp(r'/+$'), '');
}

/// HTTP client that attaches a Bearer token on every request.
class BearerTokenClient extends http.BaseClient {
  /// Creates a bearer token client.
  BearerTokenClient({
    required String token,
    required http.Client httpClient,
  }) : _token = token,
       _baseClient = httpClient;

  final String _token;
  final http.Client _baseClient;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['Authorization'] = 'Bearer $_token';
    return _baseClient.send(request);
  }
}

/// FlutterPatch CLI authentication.
///
/// Token resolution order:
/// 1. [shorebirdTokenEnvVar] environment variable
/// 2. Local [credentialsFilePath] entry keyed by `shorebird.yaml` → `base_url`
/// 3. Unauthenticated (callers should error)
class Auth {
  /// Creates a new [Auth] instance.
  Auth({
    http.Client? httpClient,
    String? credentialsDir,
  }) : _httpClient = httpClient ?? httpClientFromZone,
       _credentialsDir =
           credentialsDir ?? applicationConfigHome(executableName) {
    _loadCredentials();
  }

  static http.Client get httpClientFromZone => httpClient;

  final http.Client _httpClient;
  final String _credentialsDir;
  String? _bearerToken;
  String? _email;

  /// Path to the local credentials file (`URL → token` JSON map).
  String get credentialsFilePath {
    return p.join(_credentialsDir, 'credentials.json');
  }

  /// The underlying HTTP client (with Bearer when authenticated).
  http.Client get client {
    if (_bearerToken != null) {
      return BearerTokenClient(
        token: _bearerToken!,
        httpClient: _httpClient,
      );
    }
    return _httpClient;
  }

  /// Saves [token] for [url] (defaults to current `base_url`) in
  /// [credentialsFilePath].
  void saveToken(String token, {Uri? url}) {
    final target = url ?? shorebirdEnv.hostedUri;
    if (target == null) {
      throw Exception(
        'Missing base_url in shorebird.yaml. '
        'Set base_url before saving a local token, or use $shorebirdTokenEnvVar.',
      );
    }
    final trimmed = token.trim();
    if (trimmed.isEmpty) {
      throw Exception('Token must not be empty.');
    }

    final key = normalizeAuthUrl(target);
    final map = _readCredentialsMap();
    map[key] = trimmed;

    final file = File(credentialsFilePath);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(map),
    );

    logger.detail('[credentials] saved token for $key');
    _bearerToken = trimmed;
    _email = key;
  }

  /// Interactive OAuth login is disabled. Use [saveToken] or set
  /// [shorebirdTokenEnvVar].
  Future<void> login({required void Function(String) prompt}) async {
    throw Exception(
      'Interactive login is disabled. '
      'Set $shorebirdTokenEnvVar, or save a token for your base_url '
      'with `flutterpatch account login`.',
    );
  }

  /// Clears the in-memory token and removes the local entry for the current
  /// `base_url` (if any). Env-based auth remains until the process exits /
  /// the variable is unset.
  Future<void> logout() async {
    final hostedUri = shorebirdEnv.hostedUri;
    if (hostedUri != null) {
      final key = normalizeAuthUrl(hostedUri);
      final map = _readCredentialsMap();
      if (map.remove(key) != null) {
        final file = File(credentialsFilePath);
        if (map.isEmpty) {
          if (file.existsSync()) {
            file.deleteSync();
          }
        } else {
          file.writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert(map),
          );
        }
        logger.detail('[credentials] removed token for $key');
      }
    }
    _clearCredentials();
  }

  /// Display label for the current auth (env var name or credentials URL).
  String? get email => _email;

  /// Whether a bearer token is available from env or local credentials.
  bool get isAuthenticated => _bearerToken != null;

  void _loadCredentials() {
    final envToken = platform.environment[shorebirdTokenEnvVar];
    if (envToken != null && envToken.trim().isNotEmpty) {
      logger.detail('[env] $shorebirdTokenEnvVar detected');
      _bearerToken = envToken.trim();
      _email = shorebirdTokenEnvVar;
      return;
    }

    final hostedUri = shorebirdEnv.hostedUri;
    if (hostedUri == null) {
      logger.detail(
        'No $shorebirdTokenEnvVar and no base_url in shorebird.yaml',
      );
      return;
    }

    final key = normalizeAuthUrl(hostedUri);
    final token = _readCredentialsMap()[key];
    if (token == null || token.trim().isEmpty) {
      logger.detail(
        'No local token for $key in $credentialsFilePath',
      );
      return;
    }

    logger.detail('[credentials] token loaded for $key');
    _bearerToken = token.trim();
    _email = key;
  }

  Map<String, String> _readCredentialsMap() {
    final file = File(credentialsFilePath);
    if (!file.existsSync()) {
      return {};
    }

    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) {
        logger.detail('Malformed credentials file (expected JSON object)');
        return {};
      }

      final result = <String, String>{};
      for (final entry in decoded.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String || value is! String) {
          continue;
        }
        final normalizedKey = key.replaceAll(RegExp(r'/+$'), '');
        if (normalizedKey.isEmpty || value.trim().isEmpty) {
          continue;
        }
        result[normalizedKey] = value.trim();
      }
      return result;
    } on FormatException {
      logger.detail('Malformed credentials file (invalid JSON)');
      return {};
    } on Exception catch (error) {
      logger.detail('Failed to read credentials file: $error');
      return {};
    }
  }

  void _clearCredentials() {
    _email = null;
    _bearerToken = null;
  }

  /// Closes the underlying HTTP client.
  void close() {
    _httpClient.close();
  }
}

/// Thrown when an already authenticated user attempts to log in.
class UserAlreadyLoggedInException implements Exception {
  /// Creates the exception.
  UserAlreadyLoggedInException({this.email});

  /// The email/label of the already authenticated user.
  final String? email;
}

/// Thrown when a user lookup fails (legacy type kept for call sites).
class UserNotFoundException implements Exception {
  /// Creates the exception.
  UserNotFoundException({required this.email});

  /// The email used to locate the user.
  final String email;
}
