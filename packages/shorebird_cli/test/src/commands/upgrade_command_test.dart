import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:platform/platform.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/commands/commands.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_cli/src/shorebird_process.dart';
import 'package:test/test.dart';

import '../mocks.dart';

void main() {
  group('upgrade', () {
    late ShorebirdLogger logger;
    late Platform platform;
    late ShorebirdProcess shorebirdProcess;
    late UpgradeCommand command;

    R runWithOverrides<R>(R Function() body) {
      return runScoped(
        body,
        values: {
          loggerRef.overrideWith(() => logger),
          platformRef.overrideWith(() => platform),
          processRef.overrideWith(() => shorebirdProcess),
        },
      );
    }

    setUp(() {
      logger = MockShorebirdLogger();
      platform = MockPlatform();
      shorebirdProcess = MockShorebirdProcess();
      command = runWithOverrides(UpgradeCommand.new);

      when(() => platform.isWindows).thenReturn(false);
      when(() => platform.environment).thenReturn(const {});
      when(
        () => shorebirdProcess.stream(
          any(),
          any(),
          environment: any(named: 'environment'),
        ),
      ).thenAnswer((_) async => ExitCode.success.code);
    });

    test('can be instantiated', () {
      final command = UpgradeCommand();
      expect(command, isNotNull);
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
                'bash -s -- --force --skip-path --skip-flutter',
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
}
