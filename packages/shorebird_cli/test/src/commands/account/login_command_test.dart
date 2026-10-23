import 'dart:io';

import 'package:args/args.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/auth/auth.dart';
import 'package:shorebird_cli/src/commands/account/login_command.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:test/test.dart';

import '../../mocks.dart';

void main() {
  group(AccountLoginCommand, () {
    late ArgResults argResults;
    late Auth auth;
    late ShorebirdLogger logger;
    late ShorebirdEnv shorebirdEnv;
    late AccountLoginCommand command;

    R runWithOverrides<R>(R Function() body) {
      return runScoped(
        body,
        values: {
          authRef.overrideWith(() => auth),
          loggerRef.overrideWith(() => logger),
          shorebirdEnvRef.overrideWith(() => shorebirdEnv),
        },
      );
    }

    setUpAll(() {
      registerFallbackValue(Uri.parse('https://example.com'));
    });

    setUp(() {
      argResults = MockArgResults();
      auth = MockAuth();
      logger = MockShorebirdLogger();
      shorebirdEnv = MockShorebirdEnv();
      command = AccountLoginCommand()..testArgResults = argResults;

      when(() => argResults['token']).thenReturn('tok');
      when(() => argResults['base-url']).thenReturn(null);
      when(() => auth.credentialsFilePath).thenReturn(
        p.join(Directory.systemTemp.path, 'credentials.json'),
      );
      when(() => shorebirdEnv.canAcceptUserInput).thenReturn(true);
      when(() => auth.saveToken(any(), url: any(named: 'url'))).thenReturn(null);
    });

    test('prompts for base_url and token when shorebird.yaml is missing',
        () async {
      when(() => shorebirdEnv.hostedUri).thenReturn(null);
      when(() => argResults['token']).thenReturn(null);
      final prompts = <String>[
        'http://127.0.0.1:8080',
        'prompted-token',
      ];
      when(() => logger.prompt(any())).thenAnswer((_) => prompts.removeAt(0));

      final code = await runWithOverrides(command.run);

      expect(code, equals(ExitCode.success.code));
      verify(
        () => auth.saveToken(
          'prompted-token',
          url: Uri.parse('http://127.0.0.1:8080'),
        ),
      ).called(1);
      verify(() => logger.info(any(that: contains('Logged in')))).called(1);
    });

    test('uses --base-url when shorebird.yaml is missing', () async {
      when(() => shorebirdEnv.hostedUri).thenReturn(null);
      when(() => argResults['base-url']).thenReturn('https://api.example.com');

      final code = await runWithOverrides(command.run);

      expect(code, equals(ExitCode.success.code));
      verify(
        () => auth.saveToken(
          'tok',
          url: Uri.parse('https://api.example.com'),
        ),
      ).called(1);
    });

    test('uses shorebird.yaml base_url when present', () async {
      when(
        () => shorebirdEnv.hostedUri,
      ).thenReturn(Uri.parse('https://api.example.com'));

      final code = await runWithOverrides(command.run);

      expect(code, equals(ExitCode.success.code));
      verify(
        () => auth.saveToken(
          'tok',
          url: Uri.parse('https://api.example.com'),
        ),
      ).called(1);
      verify(() => logger.info(any(that: contains('Logged in')))).called(1);
    });

    test('requires --base-url in non-interactive mode without yaml', () async {
      when(() => shorebirdEnv.hostedUri).thenReturn(null);
      when(() => shorebirdEnv.canAcceptUserInput).thenReturn(false);

      final code = await runWithOverrides(command.run);

      expect(code, equals(ExitCode.usage.code));
      verify(
        () => logger.err(any(that: contains('Missing base_url'))),
      ).called(1);
      verifyNever(() => auth.saveToken(any(), url: any(named: 'url')));
    });

    test('rejects invalid --base-url', () async {
      when(() => shorebirdEnv.hostedUri).thenReturn(null);
      when(() => argResults['base-url']).thenReturn('not-a-url');

      final code = await runWithOverrides(command.run);

      expect(code, equals(ExitCode.usage.code));
      verify(
        () => logger.err(any(that: contains('Invalid base URL'))),
      ).called(1);
      verifyNever(() => auth.saveToken(any(), url: any(named: 'url')));
    });

    test('requires --token in non-interactive mode', () async {
      when(
        () => shorebirdEnv.hostedUri,
      ).thenReturn(Uri.parse('https://api.example.com'));
      when(() => shorebirdEnv.canAcceptUserInput).thenReturn(false);
      when(() => argResults['token']).thenReturn(null);

      final code = await runWithOverrides(command.run);

      expect(code, equals(ExitCode.usage.code));
      verifyNever(() => auth.saveToken(any(), url: any(named: 'url')));
    });
  });
}
