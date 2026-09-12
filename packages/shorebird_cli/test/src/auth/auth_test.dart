import 'dart:convert';
import 'dart:io' hide Platform;

import 'package:cli_util/cli_util.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:platform/platform.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/auth/auth.dart';
import 'package:shorebird_cli/src/http_client/http_client.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_cli/src/shorebird_cli_command_runner.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:test/test.dart';

import '../fakes.dart';
import '../mocks.dart';

void main() {
  group('normalizeAuthUrl', () {
    test('strips trailing slashes', () {
      expect(
        normalizeAuthUrl(Uri.parse('https://api.example.com/')),
        equals('https://api.example.com'),
      );
      expect(
        normalizeAuthUrl(Uri.parse('https://api.example.com')),
        equals('https://api.example.com'),
      );
    });
  });

  group('scoped', () {
    test('creates instance with default constructor', () {
      final instance = runScoped(
        () => auth,
        values: {
          authRef,
          httpClientRef.overrideWith(MockHttpClient.new),
          loggerRef.overrideWith(MockShorebirdLogger.new),
          platformRef.overrideWith(() {
            final platform = MockPlatform();
            when(() => platform.environment).thenReturn(<String, String>{});
            return platform;
          }),
          shorebirdEnvRef.overrideWith(() {
            final env = MockShorebirdEnv();
            when(() => env.hostedUri).thenReturn(null);
            return env;
          }),
        },
      );
      expect(
        instance.credentialsFilePath,
        p.join(applicationConfigHome(executableName), 'credentials.json'),
      );
    });
  });

  group(Auth, () {
    late String credentialsDir;
    late http.Client httpClient;
    late ShorebirdLogger logger;
    late Platform platform;
    late ShorebirdEnv shorebirdEnv;

    R runWithOverrides<R>(R Function() body) {
      return runScoped(
        body,
        values: {
          httpClientRef.overrideWith(() => httpClient),
          loggerRef.overrideWith(() => logger),
          platformRef.overrideWith(() => platform),
          shorebirdEnvRef.overrideWith(() => shorebirdEnv),
        },
      );
    }

    Auth buildAuth() {
      return runWithOverrides(
        () => Auth(
          credentialsDir: credentialsDir,
          httpClient: httpClient,
        ),
      );
    }

    void writeCredentials(Map<String, String> tokens) {
      File(
        p.join(credentialsDir, 'credentials.json'),
      ).writeAsStringSync(jsonEncode(tokens));
    }

    setUpAll(() {
      registerFallbackValue(FakeBaseRequest());
    });

    setUp(() {
      credentialsDir = Directory.systemTemp.createTempSync().path;
      httpClient = MockHttpClient();
      logger = MockShorebirdLogger();
      platform = MockPlatform();
      shorebirdEnv = MockShorebirdEnv();

      when(() => platform.environment).thenReturn(<String, String>{});
      when(() => shorebirdEnv.hostedUri).thenReturn(null);
    });

    group('isAuthenticated', () {
      test('is false when env and local credentials are missing', () {
        final auth = buildAuth();
        expect(auth.isAuthenticated, isFalse);
      });

      test('is true when FLUTTERPATCH_TOKEN is set', () {
        when(() => platform.environment).thenReturn(<String, String>{
          shorebirdTokenEnvVar: 'env-token',
        });
        final auth = buildAuth();
        expect(auth.isAuthenticated, isTrue);
        expect(auth.email, equals(shorebirdTokenEnvVar));
      });

      test('trims env token whitespace', () {
        when(() => platform.environment).thenReturn(<String, String>{
          shorebirdTokenEnvVar: '  env-token  \n',
        });
        final auth = buildAuth();
        expect(auth.isAuthenticated, isTrue);
      });

      test('loads local token for shorebird.yaml base_url', () {
        when(
          () => shorebirdEnv.hostedUri,
        ).thenReturn(Uri.parse('https://api.example.com'));
        writeCredentials({'https://api.example.com': 'local-token'});

        final auth = buildAuth();
        expect(auth.isAuthenticated, isTrue);
        expect(auth.email, equals('https://api.example.com'));
      });

      test('matches base_url with trailing slash in credentials', () {
        when(
          () => shorebirdEnv.hostedUri,
        ).thenReturn(Uri.parse('https://api.example.com/'));
        writeCredentials({'https://api.example.com/': 'local-token'});

        final auth = buildAuth();
        expect(auth.isAuthenticated, isTrue);
      });

      test('env token takes priority over local credentials', () async {
        when(() => platform.environment).thenReturn(<String, String>{
          shorebirdTokenEnvVar: 'env-token',
        });
        when(
          () => shorebirdEnv.hostedUri,
        ).thenReturn(Uri.parse('https://api.example.com'));
        writeCredentials({'https://api.example.com': 'local-token'});

        final auth = buildAuth();
        expect(auth.isAuthenticated, isTrue);
        expect(auth.email, equals(shorebirdTokenEnvVar));

        when(() => httpClient.send(any())).thenAnswer(
          (_) async =>
              http.StreamedResponse(const Stream.empty(), HttpStatus.ok),
        );
        await runWithOverrides(
          () => auth.client.get(Uri.parse('https://example.com')),
        );
        final captured = verify(() => httpClient.send(captureAny())).captured;
        final request = captured.single as http.BaseRequest;
        expect(request.headers['Authorization'], equals('Bearer env-token'));
      });

      test('is false when local credentials exist for a different URL', () {
        when(
          () => shorebirdEnv.hostedUri,
        ).thenReturn(Uri.parse('https://api.example.com'));
        writeCredentials({'https://other.example.com': 'local-token'});

        final auth = buildAuth();
        expect(auth.isAuthenticated, isFalse);
      });

      test('is false when credentials file is malformed', () {
        when(
          () => shorebirdEnv.hostedUri,
        ).thenReturn(Uri.parse('https://api.example.com'));
        File(
          p.join(credentialsDir, 'credentials.json'),
        ).writeAsStringSync('not-json');

        final auth = buildAuth();
        expect(auth.isAuthenticated, isFalse);
      });
    });

    group('client', () {
      test('attaches Bearer header when authenticated', () async {
        when(() => platform.environment).thenReturn(<String, String>{
          shorebirdTokenEnvVar: 'env-token',
        });
        when(() => httpClient.send(any())).thenAnswer(
          (_) async =>
              http.StreamedResponse(const Stream.empty(), HttpStatus.ok),
        );

        final auth = buildAuth();
        await runWithOverrides(
          () => auth.client.get(Uri.parse('https://example.com')),
        );

        final captured = verify(() => httpClient.send(captureAny())).captured;
        final request = captured.single as http.BaseRequest;
        expect(request.headers['Authorization'], equals('Bearer env-token'));
      });

      test('returns plain client when unauthenticated', () {
        final auth = buildAuth();
        expect(auth.client, isA<http.Client>());
        expect(auth.client, isNot(isA<BearerTokenClient>()));
      });
    });

    group('saveToken', () {
      test('writes credentials for current base_url', () {
        when(
          () => shorebirdEnv.hostedUri,
        ).thenReturn(Uri.parse('https://api.example.com/'));
        final auth = buildAuth();

        runWithOverrides(() => auth.saveToken('  saved-token  '));

        expect(auth.isAuthenticated, isTrue);
        final stored = jsonDecode(
          File(auth.credentialsFilePath).readAsStringSync(),
        ) as Map<String, dynamic>;
        expect(stored['https://api.example.com'], equals('saved-token'));
      });

      test('throws when base_url is missing', () {
        final auth = buildAuth();
        expect(
          () => runWithOverrides(() => auth.saveToken('token')),
          throwsA(isA<Exception>()),
        );
      });
    });

    group('login', () {
      test('throws because interactive OAuth is disabled', () async {
        final auth = buildAuth();
        await expectLater(
          runWithOverrides(() => auth.login(prompt: (_) {})),
          throwsA(isA<Exception>()),
        );
      });
    });

    group('logout', () {
      test('removes local credentials for current base_url', () async {
        when(
          () => shorebirdEnv.hostedUri,
        ).thenReturn(Uri.parse('https://api.example.com'));
        writeCredentials({
          'https://api.example.com': 'local-token',
          'https://other.example.com': 'other-token',
        });
        final auth = buildAuth();
        expect(auth.isAuthenticated, isTrue);

        await runWithOverrides(() => auth.logout());

        expect(auth.isAuthenticated, isFalse);
        final stored = jsonDecode(
          File(p.join(credentialsDir, 'credentials.json')).readAsStringSync(),
        ) as Map<String, dynamic>;
        expect(stored.containsKey('https://api.example.com'), isFalse);
        expect(stored['https://other.example.com'], equals('other-token'));
      });

      test('deletes credentials file when last entry is removed', () async {
        when(
          () => shorebirdEnv.hostedUri,
        ).thenReturn(Uri.parse('https://api.example.com'));
        writeCredentials({'https://api.example.com': 'local-token'});
        final auth = buildAuth();

        await runWithOverrides(() => auth.logout());

        expect(
          File(p.join(credentialsDir, 'credentials.json')).existsSync(),
          isFalse,
        );
      });
    });
  });
}
