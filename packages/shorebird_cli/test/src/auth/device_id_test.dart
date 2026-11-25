
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/auth/device_id.dart';
import 'package:test/test.dart';

void main() {
  group('resolveCliDeviceId', () {
    late Directory tempHome;

    setUp(() {
      clearCliDeviceIdCache();
      tempHome = Directory.systemTemp.createTempSync('cli_device_id_');
    });

    tearDown(() {
      clearCliDeviceIdCache();
      if (tempHome.existsSync()) {
        tempHome.deleteSync(recursive: true);
      }
    });

    test('prefers FLUTTERPATCH_DEVICE_ID override', () {
      final id = resolveCliDeviceId(
        environment: {flutterpatchDeviceIdEnvVar: '  override-id  '},
        readMachineIdRaw: () => 'machine-should-be-ignored',
        homePath: tempHome.path,
      );
      expect(id, equals('override-id'));
    });

    test('derives stable cli_ hash from machine id', () {
      final raw = 'F90B429C-0526-576F-AC37-5694417BCFC9';
      final expected = 'cli_${sha256.convert(utf8.encode(raw)).toString()}';

      final first = resolveCliDeviceId(
        environment: const {},
        readMachineIdRaw: () => raw,
        homePath: tempHome.path,
      );
      clearCliDeviceIdCache();
      final second = resolveCliDeviceId(
        environment: const {},
        readMachineIdRaw: () => raw,
        homePath: tempHome.path,
      );

      expect(first, equals(expected));
      expect(second, equals(expected));
    });

    test('persists fallback id under ~/.flutterpatch/cli_device_id', () {
      final first = resolveCliDeviceId(
        environment: const {},
        readMachineIdRaw: () => null,
        homePath: tempHome.path,
      );
      clearCliDeviceIdCache();
      final second = resolveCliDeviceId(
        environment: const {},
        readMachineIdRaw: () => null,
        homePath: tempHome.path,
      );

      expect(first, startsWith('cli_'));
      expect(second, equals(first));
      expect(
        File(p.join(tempHome.path, '.flutterpatch', 'cli_device_id'))
            .readAsStringSync()
            .trim(),
        equals(first),
      );
    });
  });

  group('resolveCliMachineFingerprint', () {
    setUp(clearCliDeviceIdCache);
    tearDown(clearCliDeviceIdCache);

    test('prefers FLUTTERPATCH_MACHINE_FINGERPRINT override', () {
      final fp = resolveCliMachineFingerprint(
        environment: {
          flutterpatchMachineFingerprintEnvVar: '  CI-FP-ABC  ',
        },
        readMachineIdRaw: () => 'machine-should-be-ignored',
      );
      expect(fp, equals('ci-fp-abc'));
    });

    test('hashes live machine id and ignores device-id override', () {
      final raw = 'F90B429C-0526-576F-AC37-5694417BCFC9';
      final expected = sha256.convert(utf8.encode(raw)).toString();
      final fp = resolveCliMachineFingerprint(
        environment: {
          flutterpatchDeviceIdEnvVar: 'copied-from-other-pc',
        },
        readMachineIdRaw: () => raw,
      );
      expect(fp, equals(expected));
    });

    test('returns empty when machine id is unavailable', () {
      final fp = resolveCliMachineFingerprint(
        environment: const {},
        readMachineIdRaw: () => null,
      );
      expect(fp, isEmpty);
    });
  });
}
