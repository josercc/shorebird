import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
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
  group(FlutterUseCommand, () {
    const version = '3.27.4';
    const revision = 'abc123def456789012345678901234567890abcd';

    late ArgResults argResults;
    late ShorebirdLogger logger;
    late ShorebirdEnv shorebirdEnv;
    late ShorebirdFlutter shorebirdFlutter;
    late FlutterUseCommand command;
    late Directory flutterDirectory;

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
      flutterDirectory = Directory.systemTemp.createTempSync();
      command = runWithOverrides(FlutterUseCommand.new)
        ..testArgResults = argResults;

      when(() => argResults.rest).thenReturn([version]);
      when(() => shorebirdEnv.flutterDirectory).thenReturn(flutterDirectory);
      when(() => shorebirdEnv.setFlutterRevision(any())).thenAnswer((_) {});
      when(
        () => shorebirdFlutter.ensureDefaultFlutterInstalled(),
      ).thenAnswer((_) async {});
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
      if (flutterDirectory.existsSync()) {
        flutterDirectory.deleteSync(recursive: true);
      }
    });

    test('has correct name and description', () {
      expect(command.name, equals('use'));
      expect(
        command.description,
        equals(
          'Set the default Shorebird Flutter SDK version '
          '(installs it if missing).',
        ),
      );
    });

    test('exits with usage when version is missing', () async {
      when(() => argResults.rest).thenReturn([]);

      final exitCode = await runWithOverrides(command.run);

      expect(exitCode, equals(ExitCode.usage.code));
      verifyNever(() => shorebirdEnv.setFlutterRevision(any()));
    });

    test('exits with software when version is not found', () async {
      when(
        () => shorebirdFlutter.resolveFlutterRevision(version),
      ).thenAnswer((_) async => null);

      final exitCode = await runWithOverrides(command.run);

      expect(exitCode, equals(ExitCode.software.code));
      verifyNever(() => shorebirdEnv.setFlutterRevision(any()));
    });

    test('exits with software when install fails', () async {
      when(
        () => shorebirdFlutter.installRevision(revision: revision),
      ).thenThrow(Exception('install failed'));

      final exitCode = await runWithOverrides(command.run);

      expect(exitCode, equals(ExitCode.software.code));
      verifyNever(() => shorebirdEnv.setFlutterRevision(any()));
    });

    test('exits with software when pin write fails', () async {
      when(
        () => shorebirdEnv.setFlutterRevision(revision),
      ).thenThrow(Exception('write failed'));

      final exitCode = await runWithOverrides(command.run);

      expect(exitCode, equals(ExitCode.software.code));
      verify(
        () => logger.err(any(that: contains('Failed to set default'))),
      ).called(1);
    });

    test('installs, pins revision, and exits successfully', () async {
      final exitCode = await runWithOverrides(command.run);

      expect(exitCode, equals(ExitCode.success.code));
      verifyInOrder([
        () => shorebirdFlutter.ensureDefaultFlutterInstalled(),
        () => shorebirdFlutter.fetchRemoteRefs(),
        () => shorebirdFlutter.resolveFlutterRevision(version),
        () => shorebirdFlutter.installRevision(revision: revision),
        () => shorebirdEnv.setFlutterRevision(revision),
        () => logger.info(any(that: contains('Now using Flutter $version'))),
      ]);
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
        command = runJsonWithOverrides(FlutterUseCommand.new)
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
        expect(data['path'], equals(flutterDirectory.path));
        verify(() => shorebirdEnv.setFlutterRevision(revision)).called(1);
        verifyNever(() => logger.info(any()));
      });
    });
  });
}
