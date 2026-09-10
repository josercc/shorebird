import 'dart:io';

import 'package:shorebird_cli/src/ota/check_ota.dart';
import 'package:shorebird_cli/src/ota/ignore_rules.dart';
import 'package:shorebird_cli/src/ota/scan_assets.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('FlutterPatchIgnore', () {
    test('parses comments and blank lines', () {
      final ignore = FlutterPatchIgnore.parse('''
# comment
lib/generated/**

*.g.dart

package:foo/**
''');
      expect(ignore.ruleCount, 3);
      expect(ignore.isIgnored('lib/generated/a.dart'), isTrue);
      expect(ignore.isIgnored('lib/main.dart'), isFalse);
      expect(ignore.isIgnored('lib/foo.g.dart'), isTrue);
      expect(ignore.isIgnored('package:foo/lib/x.dart'), isTrue);
      expect(ignore.isIgnored('package:bar/lib/x.dart'), isFalse);
    });

    test('supports negation', () {
      final ignore = FlutterPatchIgnore.parse('''
lib/generated/**
!lib/generated/keep.dart
''');
      expect(ignore.isIgnored('lib/generated/a.dart'), isTrue);
      expect(ignore.isIgnored('lib/generated/keep.dart'), isFalse);
    });

    test('directory trailing slash matches children', () {
      final ignore = FlutterPatchIgnore.parse('assets/tmp/\n');
      expect(ignore.isIgnored('assets/tmp/a.png'), isTrue);
      expect(ignore.isIgnored('assets/ok.png'), isFalse);
    });

    test('basename rules match files and directory trees', () {
      final ignore = FlutterPatchIgnore.parse('''
aar
local.properties
key.properties
unityAndroid
unityLibrary
frameworks
''');
      expect(ignore.isIgnored('local.properties'), isTrue);
      expect(ignore.isIgnored('app/local.properties'), isTrue);
      expect(ignore.isIgnored('key.properties'), isTrue);
      expect(ignore.isIgnored('unityAndroid'), isTrue);
      expect(ignore.isIgnored('unityAndroid/src/Foo.java'), isTrue);
      expect(ignore.isIgnored('unityLibrary/libs/x.so'), isTrue);
      expect(ignore.isIgnored('frameworks/Foo.framework/Foo'), isTrue);
      expect(ignore.isIgnored('aar/foo.jar'), isTrue);
      expect(ignore.isIgnored('lib/main.dart'), isFalse);
      expect(ignore.isIgnored('app/src/main/AndroidManifest.xml'), isFalse);
    });

    test('load walks up to parent .meta_otaignore', () {
      final root = Directory.systemTemp.createTempSync('meta_ota_ignore_walk_');
      addTearDown(() => root.deleteSync(recursive: true));
      final flutter = Directory(p.join(root.path, 'metaapp_flutter'))
        ..createSync();
      File(p.join(root.path, '.meta_otaignore')).writeAsStringSync('unityLibrary\n');

      final ignore = FlutterPatchIgnore.load(flutter.path);
      expect(ignore.filePath, isNotNull);
      expect(ignore.isIgnored('unityLibrary/x.java'), isTrue);
    });

    test('load missing file is empty', () {
      final dir = Directory.systemTemp.createTempSync('meta_ota_ignore_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final ignore = FlutterPatchIgnore.load(dir.path);
      expect(ignore.isEmpty, isTrue);
      expect(ignore.filePath, isNull);
    });
  });

  group('scan respects .meta_otaignore', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('meta_ota_ignore_scan_');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    Future<Directory> makeApp() async {
      final flutter = Directory(p.join(tmp.path, 'app'))..createSync();
      File(p.join(flutter.path, 'pubspec.yaml')).writeAsStringSync('''
name: demo
flutter:
  assets:
    - assets/a.txt
    - assets/skip.txt
''');
      File(p.join(flutter.path, 'lib', 'main.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('void main() {}');
      File(p.join(flutter.path, 'lib', 'generated', 'x.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('class X {}');
      File(p.join(flutter.path, 'assets', 'a.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('a');
      File(p.join(flutter.path, 'assets', 'skip.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('skip');

      Directory(p.join(flutter.path, '.dart_tool')).createSync();
      File(p.join(flutter.path, '.dart_tool', 'package_config.json'))
          .writeAsStringSync(jsonPackageConfig(flutter.path));
      File(p.join(flutter.path, 'pubspec.lock')).writeAsStringSync('''
packages:
  demo:
    dependency: "direct main"
    description:
      path: "."
      relative: true
    source: path
    version: "0.0.0"
''');
      return flutter;
    }

    test('checkOta skips ignored dart and assets', () async {
      final flutter = await makeApp();
      File(p.join(flutter.path, '.meta_otaignore')).writeAsStringSync('''
lib/generated/**
assets/skip.txt
''');

      final result = await checkOta(
        flutterDir: flutter.path,
        writeSnapshot: false,
        skipLocalBaseline: true,
      );
      final paths = result.snapshot.files.map((f) => f.path).toSet();
      expect(paths, contains('lib/main.dart'));
      expect(paths, contains('assets/a.txt'));
      expect(paths, isNot(contains('lib/generated/x.dart')));
      expect(paths, isNot(contains('assets/skip.txt')));
    });

    test('scanFlutterAssets skips ignored assets', () async {
      final flutter = await makeApp();
      File(p.join(flutter.path, '.meta_otaignore')).writeAsStringSync('''
assets/skip.txt
''');

      final result = await scanFlutterAssets(
        appDir: flutter.path,
        writeConfig: false,
      );
      final paths = result.resources.map((r) => r.path).toSet();
      expect(paths, contains('assets/a.txt'));
      expect(paths, isNot(contains('assets/skip.txt')));
    });
  });
}

String jsonPackageConfig(String appRoot) {
  final rootUri = Uri.directory(appRoot).toString();
  return '''
{
  "configVersion": 2,
  "packages": [
    {
      "name": "demo",
      "rootUri": "$rootUri",
      "packageUri": "lib/"
    }
  ]
}
''';
}
