import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/commands/commands.dart';
import 'package:shorebird_cli/src/json_output.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_flutter.dart';
import 'package:test/test.dart';

import '../../helpers.dart';
import '../../mocks.dart';

void main() {
  group(FlutterInstallCommand, () {
    const version = '3.27.4';
    const revision = 'abc123def456789012345678901234567890abcd';

    late ArgResults argResults;
    late ShorebirdLogger logger;
    late ShorebirdEnv shorebirdEnv;
    late ShorebirdFlutter shorebirdFlutter;
    late FlutterInstallCommand command;
    late Directory shorebirdRoot;

    R runWithOverrides<R>(R Function() body) {
      return runScoped(
        body,
        values: {
          isJsonModeRef.overrideWith(() => false),
          loggerRef.overrideWith(() => logger),
          shorebirdEnvRef.overrideWith(() => shorebirdEnv),
          shorebirdFlutterRef.overrideWith(() => shorebirdFlutter),
        },
      );
    }

    setUp(() {
      argResults = MockArgResults();
      logger = MockShorebirdLogger();
      shorebirdEnv = MockShorebirdEnv();
      shorebirdFlutter = MockShorebirdFlutter();
      shorebirdRoot = Directory.systemTemp.createTempSync();
      command = runWithOverrides(FlutterInstallCommand.new)
        ..testArgResults = argResults;

      when(() => argResults.rest).thenReturn([version]);
      when(() => shorebirdEnv.shorebirdRoot).thenReturn(shorebirdRoot);
      when(
        () => shorebirdFlutter.fetchRemoteRefs(),
      ).thenAnswer((_) async {});
      when(
        () => shorebirdFlutter.resolveFlutterRevision(version),
      ).thenAnswer((_) async => revision);
      when(
        () => shorebirdFlutter.installRevision(revision: revision),
      ).thenAnswer((_) async {});
      when(
        () => shorebirdFlutter.getVersionForRevision(
          flutterRevision: revision,
        ),
      ).thenAnswer((_) async => version);
    });

    tearDown(() {
      if (shorebirdRoot.existsSync()) {
        shorebirdRoot.deleteSync(recursive: true);
      }
    });

    test('has correct name and description', () {
      expect(command.name, equals('install'));
      expect(
        command.description,
        equals(
          'Install a Shorebird Flutter SDK version and its platform resources.',
        ),
      );
    });

    test('exits with usage when version is missing', () async {
      when(() => argResults.rest).thenReturn([]);

      final exitCode = await runWithOverrides(command.run);

      expect(exitCode, equals(ExitCode.usage.code));
      verify(
        () => logger.err(any(that: contains('Missing required'))),
      ).called(1);
      verifyNever(
        () => shorebirdFlutter.installRevision(
          revision: any(named: 'revision'),
        ),
      );
    });

    test('exits with software when version is not found', () async {
      when(
        () => shorebirdFlutter.resolveFlutterRevision(version),
      ).thenAnswer((_) async => null);

      final exitCode = await runWithOverrides(command.run);

      expect(exitCode, equals(ExitCode.software.code));
      verify(
        () => logger.err(any(that: contains('Version $version not found'))),
      ).called(1);
      verifyNever(
        () => shorebirdFlutter.installRevision(
          revision: any(named: 'revision'),
        ),
      );
    });

    test('exits with software when resolve throws', () async {
      when(
        () => shorebirdFlutter.resolveFlutterRevision(version),
      ).thenThrow(Exception('boom'));

      final exitCode = await runWithOverrides(command.run);

      expect(exitCode, equals(ExitCode.software.code));
      verify(
        () => logger.err(
          any(that: contains('Unable to determine revision')),
        ),
      ).called(1);
    });

    test('exits with software when install fails', () async {
      when(
        () => shorebirdFlutter.installRevision(revision: revision),
      ).thenThrow(Exception('install failed'));

      final exitCode = await runWithOverrides(command.run);

      expect(exitCode, equals(ExitCode.software.code));
      verify(
        () => logger.err(any(that: contains('Failed to install'))),
      ).called(1);
    });

    test('installs revision and exits successfully', () async {
      final exitCode = await runWithOverrides(command.run);

      expect(exitCode, equals(ExitCode.success.code));
      verifyInOrder([
        () => shorebirdFlutter.fetchRemoteRefs(),
        () => shorebirdFlutter.resolveFlutterRevision(version),
        () => shorebirdFlutter.installRevision(revision: revision),
        () => logger.info(any(that: contains('Installed Flutter $version'))),
      ]);
      verifyNever(() => shorebirdEnv.setFlutterRevision(any()));
    });

    group('when --json is passed', () {
      late List<String> stdoutOutput;

      R runJsonWithOverrides<R>(R Function() body) {
        return runScoped(
          body,
          values: {
            isJsonModeRef.overrideWith(() => true),
            loggerRef.overrideWith(() => logger),
            shorebirdEnvRef.overrideWith(() => shorebirdEnv),
            shorebirdFlutterRef.overrideWith(() => shorebirdFlutter),
          },
        );
      }

      setUp(() {
        stdoutOutput = [];
        command = runJsonWithOverrides(FlutterInstallCommand.new)
          ..testArgResults = argResults;
      });

      test('emits JSON success', () async {
        final exitCode = await captureStdout(
          () => runJsonWithOverrides(command.run),
          captured: stdoutOutput,
        );

        expect(exitCode, equals(ExitCode.success.code));
        final json = jsonDecode(stdoutOutput.first) as Map<String, dynamic>;
        expect(json['status'], equals('success'));
        final data = json['data'] as Map<String, dynamic>;
        expect(data['version'], equals(version));
        expect(data['revision'], equals(revision));
        expect(
          data['path'],
          equals(
            p.join(shorebirdRoot.path, 'bin', 'cache', 'flutter', revision),
          ),
        );
        verifyNever(() => logger.info(any()));
      });

      test('emits JSON error when version is missing', () async {
        when(() => argResults.rest).thenReturn([]);

        final exitCode = await captureStdout(
          () => runJsonWithOverrides(command.run),
          captured: stdoutOutput,
        );

        expect(exitCode, equals(ExitCode.usage.code));
        final json = jsonDecode(stdoutOutput.first) as Map<String, dynamic>;
        expect(json['status'], equals('error'));
        final error = json['error'] as Map<String, dynamic>;
        expect(error['code'], equals('usage_error'));
      });
    });
  });
}
