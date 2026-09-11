import 'dart:convert';

import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/commands/commands.dart';
import 'package:shorebird_cli/src/json_output.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:test/test.dart';

import '../helpers.dart';
import '../mocks.dart';

void main() {
  group(YamlCommand, () {
    late ShorebirdLogger logger;
    late YamlCommand command;

    R runWithOverrides<R>(
      R Function() body, {
      bool jsonMode = false,
    }) {
      return runScoped(
        body,
        values: {
          isJsonModeRef.overrideWith(() => jsonMode),
          loggerRef.overrideWith(() => logger),
        },
      );
    }

    setUp(() {
      logger = MockShorebirdLogger();
      command = runWithOverrides(YamlCommand.new);
    });

    test('has correct name and description', () {
      expect(command.name, equals('yaml'));
      expect(
        command.description,
        contains('Print documentation for supported shorebird.yaml fields.'),
      );
    });

    test('prints field documentation', () async {
      final exitCode = await runWithOverrides(command.run);

      expect(exitCode, equals(ExitCode.success.code));
      final logged =
          verify(() => logger.info(captureAny())).captured.single as String;
      expect(logged, contains('shorebird.yaml'));
      expect(logged, contains('app_id (required, string)'));
      expect(logged, contains('Default: none (required)'));
      expect(logged, contains('flavors (optional, map<string, string>)'));
      expect(logged, contains('Default: none'));
      expect(logged, contains('base_url (optional, string)'));
      expect(logged, contains('patch_verification (optional, string)'));
      expect(
        logged,
        contains('Default: strict (when patch signing is enabled)'),
      );
      expect(logged, contains('Allowed values: strict, install_only'));
      expect(logged, contains('upload_baselines (optional, bool)'));
      expect(logged, contains('Default: false'));
      expect(logged, contains('upload_patch_resources (optional, bool)'));
      expect(logged, contains('Minimal example:'));
    });

    test('emits JSON documentation in --json mode', () async {
      final stdoutOutput = <String>[];
      final exitCode = await captureStdout(
        () => runWithOverrides(command.run, jsonMode: true),
        captured: stdoutOutput,
      );

      expect(exitCode, equals(ExitCode.success.code));
      expect(stdoutOutput, isNotEmpty);
      final json = jsonDecode(stdoutOutput.first) as Map<String, dynamic>;
      expect(json['status'], equals('success'));
      expect(
        (json['meta'] as Map<String, dynamic>)['command'],
        equals('yaml'),
      );
      final data = json['data'] as Map<String, dynamic>;
      expect(data['file'], equals('shorebird.yaml'));
      final fields = data['fields'] as List<dynamic>;
      expect(
        fields.map((f) => (f as Map)['name']),
        equals([
          'app_id',
          'flavors',
          'base_url',
          'patch_verification',
          'upload_baselines',
          'upload_patch_resources',
        ]),
      );
      expect(
        fields.map((f) => (f as Map)['default']),
        equals([
          'none (required)',
          'none',
          'none',
          'strict (when patch signing is enabled)',
          'false',
          'false',
        ]),
      );
      verifyNever(() => logger.info(any()));
    });
  });
}
