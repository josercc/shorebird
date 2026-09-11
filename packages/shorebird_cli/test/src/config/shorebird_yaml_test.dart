import 'package:checked_yaml/checked_yaml.dart';
import 'package:shorebird_cli/src/config/config.dart';
import 'package:test/test.dart';

void main() {
  group('ShorebirdYaml', () {
    test('can be deserialized without flavors', () {
      const yaml = '''
app_id: test_app_id
base_url: https://example.com
''';
      final shorebirdYaml = checkedYamlDecode(
        yaml,
        (m) => ShorebirdYaml.fromJson(m!),
      );
      expect(shorebirdYaml.appId, 'test_app_id');
      expect(shorebirdYaml.flavors, isNull);
      expect(shorebirdYaml.baseUrl, 'https://example.com');
    });

    test('can be deserialized with flavors', () {
      const yaml = '''
app_id: test_app_id1
flavors:
  development: test_app_id1
  production: test_app_id2
base_url: https://example.com
''';
      final shorebirdYaml = checkedYamlDecode(
        yaml,
        (m) => ShorebirdYaml.fromJson(m!),
      );
      expect(shorebirdYaml.appId, equals('test_app_id1'));
      expect(shorebirdYaml.flavors, {
        'development': 'test_app_id1',
        'production': 'test_app_id2',
      });
      expect(shorebirdYaml.baseUrl, 'https://example.com');
    });

    test('can be deserialized with only app_id', () {
      const yaml = '''
app_id: test_app_id
''';
      final shorebirdYaml = checkedYamlDecode(
        yaml,
        (m) => ShorebirdYaml.fromJson(m!),
      );
      expect(shorebirdYaml.appId, 'test_app_id');
      expect(shorebirdYaml.flavors, isNull);
      expect(shorebirdYaml.baseUrl, isNull);
    });

    test('can be deserialized without auto_update', () {
      const yaml = '''
app_id: test_app_id
''';
      final shorebirdYaml = checkedYamlDecode(
        yaml,
        (m) => ShorebirdYaml.fromJson(m!),
      );
      expect(shorebirdYaml.appId, 'test_app_id');
      expect(shorebirdYaml.autoUpdate, isNull);
    });

    test('can be deserialized with auto_update', () {
      const yaml = '''
app_id: test_app_id
auto_update: true
''';
      final shorebirdYaml = checkedYamlDecode(
        yaml,
        (m) => ShorebirdYaml.fromJson(m!),
      );
      expect(shorebirdYaml.appId, 'test_app_id');
      expect(shorebirdYaml.flavors, isNull);
      expect(shorebirdYaml.baseUrl, isNull);
      expect(shorebirdYaml.autoUpdate, isTrue);
    });

    test('can be deserialized with auto_update: false', () {
      const yaml = '''
app_id: test_app_id
auto_update: false
''';
      final shorebirdYaml = checkedYamlDecode(
        yaml,
        (m) => ShorebirdYaml.fromJson(m!),
      );
      expect(shorebirdYaml.appId, 'test_app_id');
      expect(shorebirdYaml.autoUpdate, isFalse);
    });

    test('can be deserialized without patch_verification', () {
      const yaml = '''
app_id: test_app_id
''';
      final shorebirdYaml = checkedYamlDecode(
        yaml,
        (m) => ShorebirdYaml.fromJson(m!),
      );
      expect(shorebirdYaml.appId, 'test_app_id');
      expect(shorebirdYaml.patchVerification, isNull);
    });

    test('can be deserialized with patch_verification: strict', () {
      const yaml = '''
app_id: test_app_id
patch_verification: strict
''';
      final shorebirdYaml = checkedYamlDecode(
        yaml,
        (m) => ShorebirdYaml.fromJson(m!),
      );
      expect(shorebirdYaml.appId, 'test_app_id');
      expect(shorebirdYaml.patchVerification, PatchVerification.strict);
    });

    test('can be deserialized with patch_verification: install_only', () {
      const yaml = '''
app_id: test_app_id
patch_verification: install_only
''';
      final shorebirdYaml = checkedYamlDecode(
        yaml,
        (m) => ShorebirdYaml.fromJson(m!),
      );
      expect(shorebirdYaml.appId, 'test_app_id');
      expect(shorebirdYaml.patchVerification, PatchVerification.installOnly);
    });

    test('throws when patch_verification has invalid value', () {
      const yaml = '''
app_id: test_app_id
patch_verification: invalid_value
''';
      expect(
        () => checkedYamlDecode(yaml, (m) => ShorebirdYaml.fromJson(m!)),
        throwsA(
          isA<ParsedYamlException>().having(
            (e) => e.message,
            'message',
            contains('patch_verification'),
          ),
        ),
      );
    });

    test('can be deserialized with upload_baselines and upload_patch_resources',
        () {
      const yaml = '''
app_id: test_app_id
upload_baselines: true
upload_patch_resources: true
''';
      final shorebirdYaml = checkedYamlDecode(
        yaml,
        (m) => ShorebirdYaml.fromJson(m!),
      );
      expect(shorebirdYaml.appId, 'test_app_id');
      expect(shorebirdYaml.uploadBaselines, isTrue);
      expect(shorebirdYaml.uploadPatchResources, isTrue);
    });

    test('defaults upload_baselines and upload_patch_resources to null', () {
      const yaml = '''
app_id: test_app_id
''';
      final shorebirdYaml = checkedYamlDecode(
        yaml,
        (m) => ShorebirdYaml.fromJson(m!),
      );
      expect(shorebirdYaml.uploadBaselines, isNull);
      expect(shorebirdYaml.uploadPatchResources, isNull);
    });

    test('can be deserialized with flutter/android/ios paths', () {
      const yaml = '''
app_id: test_app_id
flutter: .
android: ../android_host
ios: ../ios_host
''';
      final shorebirdYaml = checkedYamlDecode(
        yaml,
        (m) => ShorebirdYaml.fromJson(m!),
      );
      expect(shorebirdYaml.appId, 'test_app_id');
      expect(shorebirdYaml.flutter, '.');
      expect(shorebirdYaml.android, '../android_host');
      expect(shorebirdYaml.ios, '../ios_host');
    });

    test('defaults flutter/android/ios to null', () {
      const yaml = '''
app_id: test_app_id
''';
      final shorebirdYaml = checkedYamlDecode(
        yaml,
        (m) => ShorebirdYaml.fromJson(m!),
      );
      expect(shorebirdYaml.flutter, isNull);
      expect(shorebirdYaml.android, isNull);
      expect(shorebirdYaml.ios, isNull);
    });

    group('AppIdExtension', () {
      test('getAppId returns base app id when no flavor is provided', () {
        const shorebirdYaml = ShorebirdYaml(appId: 'test_app_id');
        expect(shorebirdYaml.getAppId(), 'test_app_id');
      });

      test('getAppId returns base app id when flavor is not found', () {
        const shorebirdYaml = ShorebirdYaml(
          appId: 'test_app_id',
          flavors: {
            'development': 'test_app_id1',
            'production': 'test_app_id2',
          },
        );
        expect(shorebirdYaml.getAppId(flavor: 'staging'), 'test_app_id');
      });

      test('getAppId returns app id for flavor', () {
        const shorebirdYaml = ShorebirdYaml(
          appId: 'test_app_id',
          flavors: {
            'development': 'test_app_id1',
            'production': 'test_app_id2',
          },
        );
        expect(shorebirdYaml.getAppId(flavor: 'development'), 'test_app_id1');
        expect(shorebirdYaml.getAppId(flavor: 'production'), 'test_app_id2');
      });
    });
  });
}
