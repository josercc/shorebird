// flutterpatch: ownership=REPLACE — auth via FLUTTERPATCH_TOKEN only
import 'package:cli_util/cli_util.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/http_client/http_client.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_cli/src/shorebird_cli_command_runner.dart';

export 'ci_token.dart';

/// A reference to an [Auth] instance.
final authRef = create(Auth.new);

/// The [Auth] instance available in the current zone.
Auth get auth => read(authRef);

/// The environment variable that holds the FlutterPatch admin/API token.
const shorebirdTokenEnvVar = 'FLUTTERPATCH_TOKEN';

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

/// FlutterPatch CLI authentication (token-only).
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

  /// Legacy path kept for message compatibility (token is env-only).
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

  /// Interactive login is disabled — set [shorebirdTokenEnvVar].
  Future<void> login({required void Function(String) prompt}) async {
    throw Exception(
      'Interactive login is disabled. Set $shorebirdTokenEnvVar instead.',
    );
  }

  /// Clears the in-memory token (env must be unset to fully log out).
  Future<void> logout() async {
    _clearCredentials();
  }

  /// Display label for the current auth (env var name when using token).
  String? get email => _email;

  /// Whether [FLUTTERPATCH_TOKEN] is set.
  bool get isAuthenticated => _bearerToken != null;

  void _loadCredentials() {
    final envToken = platform.environment[shorebirdTokenEnvVar];
    if (envToken == null || envToken.trim().isEmpty) {
      return;
    }
    final trimmed = envToken.trim();
    logger.detail('[env] $shorebirdTokenEnvVar detected');
    _bearerToken = trimmed;
    _email = shorebirdTokenEnvVar;
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
