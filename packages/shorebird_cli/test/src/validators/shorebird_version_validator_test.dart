import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_version.dart';
import 'package:shorebird_cli/src/validators/validators.dart';
import 'package:test/test.dart';

import '../mocks.dart';

void main() {
  group('ShorebirdVersionValidator', () {
    late ShorebirdEnv shorebirdEnv;
    late ShorebirdVersion shorebirdVersion;
    late ShorebirdVersionValidator validator;

    R runWithOverrides<R>(R Function() body) {
      return runScoped(
        body,
        values: {
          shorebirdEnvRef.overrideWith(() => shorebirdEnv),
          shorebirdVersionRef.overrideWith(() => shorebirdVersion),
        },
      );
    }

    setUp(() {
      shorebirdEnv = MockShorebirdEnv();
      shorebirdVersion = MockShorebirdVersion();
      validator = ShorebirdVersionValidator();

      when(() => shorebirdEnv.isGitInstall).thenReturn(true);
      when(shorebirdVersion.isLatest).thenAnswer((_) async => false);
    });

    test('has a non-empty description', () {
      expect(validator.description, isNotEmpty);
    });

    test('canRunInContext always returns true', () {
      expect(validator.canRunInCurrentContext(), isTrue);
    });

    test('returns no issues for packaged (non-git) installs', () async {
      when(() => shorebirdEnv.isGitInstall).thenReturn(false);

      final results = await runWithOverrides(validator.validate);

      expect(results, isEmpty);
      verifyNever(shorebirdVersion.isLatest);
    });

    test('returns no issues when shorebird is up-to-date', () async {
      when(shorebirdVersion.isLatest).thenAnswer((_) async => true);

      final results = await runWithOverrides(validator.validate);

      expect(results, isEmpty);
    });

    test(
      'returns an error when shorebird version cannot be determined',
      () async {
        when(
          shorebirdVersion.isLatest,
        ).thenThrow(const ProcessException('git', ['rev-parse', 'HEAD']));

        final results = await runWithOverrides(validator.validate);

        expect(results, hasLength(1));
        expect(results.first.severity, ValidationIssueSeverity.error);
        expect(
          results.first.message,
          contains('Failed to get FlutterPatch version'),
        );
      },
    );

    test('returns a warning when a newer shorebird is available', () async {
      when(shorebirdVersion.isLatest).thenAnswer((_) async => false);

      final results = await runWithOverrides(validator.validate);

      expect(results, hasLength(1));
      expect(results.first.severity, ValidationIssueSeverity.warning);
      expect(
        results.first.message,
        contains('A new version of FlutterPatch is available!'),
      );
    });
  });
}
