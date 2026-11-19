import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/commands/preview/module_preview.dart';
import 'package:shorebird_cli/src/config/config.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';
import 'package:test/test.dart';

import '../../mocks.dart';

void main() {
  group('module_preview', () {
    late ShorebirdLogger logger;

    setUp(() {
      logger = MockShorebirdLogger();
    });

    test('resolvePreviewPath joins relative paths against config root', () {
      final root = Directory.systemTemp.createTempSync();
      expect(
        resolvePreviewPath(path: '../host', configRoot: root),
        p.normalize(p.join(root.path, '../host')),
      );
    });

    test('resolvePreviewPath keeps absolute paths', () {
      final absolute = p.join(Directory.systemTemp.path, 'host');
      expect(
        resolvePreviewPath(
          path: absolute,
          configRoot: Directory.systemTemp,
        ),
        p.normalize(absolute),
      );
    });

    test('missingModulePreviewConfigMessage mentions shorebird.yaml', () {
      expect(
        missingModulePreviewConfigMessage(platform: ReleasePlatform.android),
        contains('android:'),
      );
      expect(
        missingModulePreviewConfigMessage(platform: ReleasePlatform.android),
        contains('host_project:'),
      );
      expect(
        missingModulePreviewConfigMessage(platform: ReleasePlatform.ios),
        contains('ios:'),
      );
    });

    test('requireAndroidPreviewConfig returns null when missing', () {
      expect(
        requireAndroidPreviewConfig(yaml: null, logger: logger),
        isNull,
      );
      verify(
        () => logger.err(
          any(that: contains('android:')),
        ),
      ).called(1);
    });

    test('requireAndroidPreviewConfig returns config when present', () {
      const yaml = ShorebirdYaml(
        appId: 'app',
        preview: PreviewConfig(
          android: PreviewAndroidConfig(
            hostProject: '../android',
            artifactDir: 'release',
            applicationId: 'com.example.host',
          ),
        ),
      );
      final config = requireAndroidPreviewConfig(yaml: yaml, logger: logger);
      expect(config?.hostProject, '../android');
      expect(config?.assembleTask, ':app:assembleRelease');
      verifyNever(() => logger.err(any()));
    });

    test(
      'requireAndroidPreviewConfig falls back to top-level android path',
      () {
        final root = Directory.systemTemp.createTempSync();
        final host = Directory(p.join(root.path, 'android_host'))
          ..createSync();
        File(p.join(host.path, 'app', 'build.gradle'))
          ..createSync(recursive: true)
          ..writeAsStringSync(
            'defaultConfig { applicationId "com.example.android_host" }',
          );

        const yaml = ShorebirdYaml(
          appId: 'app',
          android: 'android_host',
        );
        final config = requireAndroidPreviewConfig(
          yaml: yaml,
          logger: logger,
          configRoot: root,
        );
        expect(config?.hostProject, 'android_host');
        expect(config?.artifactDir, 'release');
        expect(config?.applicationId, 'com.example.android_host');
        verifyNever(() => logger.err(any()));
      },
    );

    test('requireIosPreviewConfig returns null when missing', () {
      expect(
        requireIosPreviewConfig(
          yaml: const ShorebirdYaml(appId: 'app'),
          logger: logger,
        ),
        isNull,
      );
      verify(
        () => logger.err(any(that: contains('ios:'))),
      ).called(1);
    });

    test('requireIosPreviewConfig falls back to top-level ios path', () {
      final root = Directory.systemTemp.createTempSync();
      final host = Directory(p.join(root.path, 'ios_host'))..createSync();
      Directory(p.join(host.path, 'ios_host.xcodeproj')).createSync();

      const yaml = ShorebirdYaml(
        appId: 'app',
        ios: 'ios_host',
      );
      final config = requireIosPreviewConfig(
        yaml: yaml,
        logger: logger,
        configRoot: root,
      );
      expect(config?.hostProject, 'ios_host');
      expect(config?.frameworksDir, 'ios_host/Flutter');
      expect(config?.scheme, 'ios_host');
      expect(config?.configuration, 'Release');
      verifyNever(() => logger.err(any()));
    });

    test('moduleAarArtifactPath builds maven layout', () {
      expect(
        moduleAarArtifactPath(
          artifactDir: '/repo',
          packageName: 'com.example.mod',
          buildNumber: '1.0',
        ),
        p.join(
          '/repo',
          'com',
          'example',
          'mod',
          'flutter_release',
          '1.0',
          'flutter_release-1.0.aar',
        ),
      );
    });

    test('findNewestHostApk returns newest apk under app outputs', () {
      final host = Directory.systemTemp.createTempSync();
      final older = File(
        p.join(host.path, 'app', 'build', 'outputs', 'apk', 'debug', 'a.apk'),
      )..createSync(recursive: true);
      final newer = File(
        p.join(host.path, 'app', 'build', 'outputs', 'apk', 'debug', 'b.apk'),
      )..createSync(recursive: true);
      older.setLastModifiedSync(DateTime(2020));
      newer.setLastModifiedSync(DateTime(2024));

      expect(findNewestHostApk(host)?.path, newer.path);
    });

    test('resolveXcodeBuildTargetArgs prefers configured workspace', () {
      final host = Directory.systemTemp.createTempSync();
      final workspace = Directory(p.join(host.path, 'App.xcworkspace'))
        ..createSync();
      Directory(p.join(host.path, 'App.xcodeproj')).createSync();

      expect(
        resolveXcodeBuildTargetArgs(
          hostProject: host,
          config: PreviewIosConfig(
            hostProject: host.path,
            frameworksDir: host.path,
            scheme: 'App',
            workspace: 'App.xcworkspace',
          ),
        ),
        ['-workspace', workspace.path],
      );
    });

    test('findBuiltIosApp finds app under derived data products', () {
      final derived = Directory.systemTemp.createTempSync();
      final app = Directory(
        p.join(
          derived.path,
          'Build',
          'Products',
          'Debug-iphoneos',
          'Host.app',
        ),
      )..createSync(recursive: true);

      expect(
        findBuiltIosApp(derivedData: derived, configuration: 'Debug')?.path,
        app.path,
      );
    });
  });
}
