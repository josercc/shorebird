import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:platform/platform.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/commands/commands.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_process.dart';
import 'package:shorebird_cli/src/shorebird_version.dart';
import 'package:test/test.dart';

import '../mocks.dart';

void main() {
  const currentShorebirdRevision = 'revision-1';
  const newerShorebirdRevision = 'revision-2';

  group('upgrade', () {
    late ShorebirdLogger logger;
    late Platform platform;
    late ShorebirdEnv shorebirdEnv;
    late ShorebirdProcess shorebirdProcess;
    late ShorebirdVersion shorebirdVersion;
    late UpgradeCommand command;

    R runWithOverrides<R>(R Function() body) {
      return runScoped(
        body,
        values: {
          loggerRef.overrideWith(() => logger),
          platformRef.overrideWith(() => platform),
          processRef.overrideWith(() => shorebirdProcess),
          shorebirdEnvRef.overrideWith(() => shorebirdEnv),
          shorebirdVersionRef.overrideWith(() => shorebirdVersion),
        },
      );
    }

    setUp(() {
      final progress = MockProgress();

      logger = MockShorebirdLogger();
      platform = MockPlatform();
      shorebirdEnv = MockShorebirdEnv();
      shorebirdProcess = MockShorebirdProcess();
      shorebirdVersion = MockShorebirdVersion();
      command = runWithOverrides(UpgradeCommand.new);

      when(() => platform.isWindows).thenReturn(false);
      when(() => platform.environment).thenReturn(const {});
      when(() => shorebirdEnv.isGitInstall).thenReturn(true);

      when(
        shorebirdVersion.fetchCurrentGitHash,
      ).thenAnswer((_) async => currentShorebirdRevision);
      when(
        shorebirdVersion.fetchLatestGitHash,
      ).thenAnswer((_) async => newerShorebirdRevision);
      when(
        () => shorebirdVersion.attemptReset(revision: any(named: 'revision')),
      ).thenAnswer((_) async => {});

      when(() => logger.progress(any())).thenReturn(progress);
    });

    test('can be instantiated', () {
      final command = UpgradeCommand();
      expect(command, isNotNull);
    });

    group('git install', () {
      test('handles errors when determining the current version', () async {
        const errorMessage = 'oops';
        when(
          shorebirdVersion.fetchCurrentGitHash,
        ).thenThrow(const ProcessException('git', ['rev-parse'], errorMessage));

        final result = await runWithOverrides(command.run);

        expect(result, equals(ExitCode.software.code));
        verify(() => logger.progress('Checking for updates')).called(1);
        verify(
          () => logger.err('Fetching current version failed: $errorMessage'),
        ).called(1);
      });

      test('handles errors when determining the latest version', () async {
        const errorMessage = 'oops';
        when(
          shorebirdVersion.fetchLatestGitHash,
        ).thenThrow(const ProcessException('git', ['rev-parse'], errorMessage));

        final result = await runWithOverrides(command.run);

        expect(result, equals(ExitCode.software.code));
        verify(() => logger.progress('Checking for updates')).called(1);
        verify(
          () => logger.err('Checking for updates failed: oops'),
        ).called(1);
      });

      test('handles errors when updating', () async {
        const errorMessage = 'oops';
        when(
          () => shorebirdVersion.attemptReset(revision: any(named: 'revision')),
        ).thenThrow(const ProcessException('git', ['reset'], errorMessage));

        final result = await runWithOverrides(command.run);

        expect(result, equals(ExitCode.software.code));
        verify(() => logger.progress('Checking for updates')).called(1);
        verify(() => logger.err('Updating failed: oops')).called(1);
      });

      test('updates when newer version exists', () async {
        when(() => logger.progress(any())).thenReturn(MockProgress());

        final result = await runWithOverrides(command.run);

        expect(result, equals(ExitCode.success.code));
        verify(() => logger.progress('Checking for updates')).called(1);
        verify(() => logger.progress('Updating')).called(1);
      });

      test('does not update when already on latest version', () async {
        when(
          shorebirdVersion.fetchLatestGitHash,
        ).thenAnswer((_) async => currentShorebirdRevision);
        when(() => logger.progress(any())).thenReturn(MockProgress());

        final result = await runWithOverrides(command.run);

        expect(result, equals(ExitCode.success.code));
        verify(
          () => logger.info('FlutterPatch is already at the latest version.'),
        ).called(1);
      });
    });

    group('packaged install', () {
      setUp(() {
        when(() => shorebirdEnv.isGitInstall).thenReturn(false);
        when(
          () => shorebirdProcess.stream(
            any(),
            any(),
            environment: any(named: 'environment'),
          ),
        ).thenAnswer((_) async => ExitCode.success.code);
      });

      test('runs install.sh via curl|bash on unix', () async {
        final result = await runWithOverrides(command.run);

        expect(result, equals(ExitCode.success.code));
        verify(
          () => shorebirdProcess.stream(
            'bash',
            [
              '-c',
              'curl -fsSL "\$FLUTTERPATCH_INSTALL_URL" | '
                  'bash -s -- --force --skip-path',
            ],
            environment: any(
              named: 'environment',
              that: containsPair(
                UpgradeCommand.installUrlEnvVar,
                UpgradeCommand.defaultInstallScriptUrl,
              ),
            ),
          ),
        ).called(1);
        verify(
          () => logger.info('FlutterPatch upgraded successfully.'),
        ).called(1);
      });

      test('uses FLUTTERPATCH_INSTALL_URL override', () async {
        const customUrl = 'https://example.com/install.sh';
        when(
          () => platform.environment,
        ).thenReturn({UpgradeCommand.installUrlEnvVar: customUrl});

        final result = await runWithOverrides(command.run);

        expect(result, equals(ExitCode.success.code));
        verify(
          () => shorebirdProcess.stream(
            'bash',
            any(),
            environment: any(
              named: 'environment',
              that: containsPair(UpgradeCommand.installUrlEnvVar, customUrl),
            ),
          ),
        ).called(1);
      });

      test('runs install.ps1 on windows', () async {
        when(() => platform.isWindows).thenReturn(true);

        final result = await runWithOverrides(command.run);

        expect(result, equals(ExitCode.success.code));
        verify(
          () => shorebirdProcess.stream(
            'powershell',
            any(
              that: containsAll([
                '-NoProfile',
                '-ExecutionPolicy',
                'Bypass',
                '-Command',
              ]),
            ),
            environment: any(
              named: 'environment',
              that: containsPair(
                UpgradeCommand.installUrlEnvVar,
                UpgradeCommand.defaultInstallScriptUrlWindows,
              ),
            ),
          ),
        ).called(1);
      });

      test('returns installer exit code on failure', () async {
        when(
          () => shorebirdProcess.stream(
            any(),
            any(),
            environment: any(named: 'environment'),
          ),
        ).thenAnswer((_) async => 42);

        final result = await runWithOverrides(command.run);

        expect(result, equals(42));
        verify(() => logger.err('Upgrade failed (exit code 42).')).called(1);
      });

      test('handles process exceptions', () async {
        when(
          () => shorebirdProcess.stream(
            any(),
            any(),
            environment: any(named: 'environment'),
          ),
        ).thenThrow(Exception('network down'));

        final result = await runWithOverrides(command.run);

        expect(result, equals(ExitCode.software.code));
        verify(
          () => logger.err('Upgrade failed: Exception: network down'),
        ).called(1);
      });
    });
  });
}
