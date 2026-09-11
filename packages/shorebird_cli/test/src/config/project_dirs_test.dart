import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/config/config.dart';
import 'package:test/test.dart';

void main() {
  group('resolveProjectDirs', () {
    late Directory tempDir;
    late Directory yamlRoot;
    late Directory cwd;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('project_dirs_');
      yamlRoot = Directory(p.join(tempDir.path, 'config'))..createSync();
      cwd = Directory(p.join(tempDir.path, 'cwd'))..createSync();
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('defaults flutter to cwd when no cli or yaml path', () {
      final dirs = resolveProjectDirs(
        yamlRoot: yamlRoot,
        cwd: cwd,
      );
      expect(dirs.flutter, p.normalize(p.absolute(cwd.path)));
      expect(dirs.android, isNull);
      expect(dirs.ios, isNull);
    });

    test('uses shorebird.yaml flutter/android/ios relative to yaml root', () {
      final flutter = Directory(p.join(yamlRoot.path, 'my_flutter'))
        ..createSync();
      final android = Directory(p.join(yamlRoot.path, 'native_android'))
        ..createSync();
      final ios = Directory(p.join(yamlRoot.path, 'native_ios'))..createSync();

      final dirs = resolveProjectDirs(
        yaml: const ShorebirdYaml(
          appId: 'app',
          flutter: 'my_flutter',
          android: 'native_android',
          ios: 'native_ios',
        ),
        yamlRoot: yamlRoot,
        cwd: cwd,
      );

      expect(dirs.flutter, p.normalize(p.absolute(flutter.path)));
      expect(dirs.android, p.normalize(p.absolute(android.path)));
      expect(dirs.ios, p.normalize(p.absolute(ios.path)));
    });

    test('cli flags override yaml values', () {
      final cliFlutter = Directory(p.join(tempDir.path, 'cli_flutter'))
        ..createSync();
      final cliAndroid = Directory(p.join(tempDir.path, 'cli_android'))
        ..createSync();
      final cliIos = Directory(p.join(tempDir.path, 'cli_ios'))..createSync();

      final dirs = resolveProjectDirs(
        flutterCli: cliFlutter.path,
        androidCli: cliAndroid.path,
        iosCli: cliIos.path,
        yaml: const ShorebirdYaml(
          appId: 'app',
          flutter: 'ignored',
          android: 'ignored',
          ios: 'ignored',
        ),
        yamlRoot: yamlRoot,
        cwd: cwd,
      );

      expect(dirs.flutter, p.normalize(p.absolute(cliFlutter.path)));
      expect(dirs.android, p.normalize(p.absolute(cliAndroid.path)));
      expect(dirs.ios, p.normalize(p.absolute(cliIos.path)));
    });

    test('discovers android/ios under flutter when not configured', () {
      final flutter = Directory(p.join(cwd.path, 'app'))..createSync();
      final android = Directory(p.join(flutter.path, 'android'))..createSync();
      final ios = Directory(p.join(flutter.path, 'ios'))..createSync();

      final dirs = resolveProjectDirs(
        flutterCli: flutter.path,
        yamlRoot: yamlRoot,
        cwd: cwd,
      );

      expect(dirs.flutter, p.normalize(p.absolute(flutter.path)));
      expect(dirs.android, p.normalize(p.absolute(android.path)));
      expect(dirs.ios, p.normalize(p.absolute(ios.path)));
    });

    test('accepts absolute paths from yaml', () {
      final flutter = Directory(p.join(tempDir.path, 'abs_flutter'))
        ..createSync();
      final android = Directory(p.join(tempDir.path, 'abs_android'))
        ..createSync();

      final dirs = resolveProjectDirs(
        yaml: ShorebirdYaml(
          appId: 'app',
          flutter: flutter.path,
          android: android.path,
        ),
        yamlRoot: yamlRoot,
        cwd: cwd,
      );

      expect(dirs.flutter, p.normalize(p.absolute(flutter.path)));
      expect(dirs.android, p.normalize(p.absolute(android.path)));
    });
  });
}
