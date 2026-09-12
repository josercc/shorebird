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

    setUp(() {
      argResults = MockArgResults();
      auth = MockAuth();
      logger = MockShorebirdLogger();
      shorebirdEnv = MockShorebirdEnv();
      command = AccountLoginCommand()..testArgResults = argResults;

      when(() => argResults['token']).thenReturn('tok');
      when(() => auth.credentialsFilePath).thenReturn(
        p.join(Directory.systemTemp.path, 'credentials.json'),
      );
      when(() => shorebirdEnv.canAcceptUserInput).thenReturn(true);
      when(() => auth.saveToken(any())).thenReturn(null);
    });

    test('fails when base_url is missing', () async {
      when(() => shorebirdEnv.hostedUri).thenReturn(null);

      final code = await runWithOverrides(command.run);

      expect(code, equals(ExitCode.config.code));
      verify(
        () => logger.err(any(that: contains('Missing base_url'))),
      ).called(1);
    });

    test('saves token for current base_url', () async {
      when(
        () => shorebirdEnv.hostedUri,
      ).thenReturn(Uri.parse('https://api.example.com'));

      final code = await runWithOverrides(command.run);

      expect(code, equals(ExitCode.success.code));
      verify(() => auth.saveToken('tok')).called(1);
      verify(() => logger.info(any(that: contains('Logged in')))).called(1);
    });

    test('requires --token in non-interactive mode', () async {
      when(
        () => shorebirdEnv.hostedUri,
      ).thenReturn(Uri.parse('https://api.example.com'));
      when(() => shorebirdEnv.canAcceptUserInput).thenReturn(false);
      when(() => argResults['token']).thenReturn(null);

      final code = await runWithOverrides(command.run);

      expect(code, equals(ExitCode.usage.code));
      verifyNever(() => auth.saveToken(any()));
    });
  });
}
