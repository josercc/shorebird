import 'dart:convert';
import 'dart:io';

import 'package:shorebird_cli/src/ota/check_ota.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('meta_ota_check_ota_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<Directory> makeApp({bool withDep = false}) async {
    final flutter = Directory(p.join(tmp.path, 'app'))..createSync();
    final android = Directory(p.join(tmp.path, 'android'))..createSync();
    final ios = Directory(p.join(tmp.path, 'ios'))..createSync();

    final depsYaml = withDep
        ? '''
dependencies:
  dep_pkg:
    path: ../dep_pkg
'''
        : '';

    File(p.join(flutter.path, 'pubspec.yaml')).writeAsStringSync('''
name: demo
$depsYaml
flutter:
  assets:
    - assets/a.txt
''');
    File(p.join(flutter.path, 'lib', 'main.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync("void main() {}");
    File(p.join(flutter.path, 'assets', 'a.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('asset-v1');

    File(p.join(android.path, 'app', 'src', 'main', 'AndroidManifest.xml'))
      ..createSync(recursive: true)
      ..writeAsStringSync('<manifest/>');
    File(p.join(android.path, 'app', 'src', 'main', 'kotlin', 'MainActivity.kt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('class MainActivity');

    File(p.join(ios.path, 'Runner', 'AppDelegate.swift'))
      ..createSync(recursive: true)
      ..writeAsStringSync('import Flutter');
    File(p.join(ios.path, 'Podfile')).writeAsStringSync('platform :ios');

    final packages = <Map<String, String>>[
      {'name': 'demo', 'rootUri': '../', 'packageUri': 'lib/'},
    ];

    if (withDep) {
      final dep = Directory(p.join(tmp.path, 'dep_pkg'))..createSync();
      File(p.join(dep.path, 'pubspec.yaml')).writeAsStringSync('''
name: dep_pkg
flutter:
  assets:
    - assets/icon.png
''');
      File(p.join(dep.path, 'lib', 'dep.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('class Dep {}');
      File(p.join(dep.path, 'assets', 'icon.png'))
        ..createSync(recursive: true)
        ..writeAsStringSync('png-v1');
      File(p.join(dep.path, 'android', 'src', 'main', 'java', 'P.java'))
        ..createSync(recursive: true)
        ..writeAsStringSync('class P {}');

      File(p.join(flutter.path, 'pubspec.lock')).writeAsStringSync('''
packages:
  dep_pkg:
    dependency: "direct main"
    description:
      path: "../dep_pkg"
      relative: true
    source: path
    version: "0.0.0"
''');
      packages.add({
        'name': 'dep_pkg',
        'rootUri': p.toUri(dep.path).toString(),
        'packageUri': 'lib/',
      });
    }

    File(p.join(flutter.path, '.dart_tool', 'package_config.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'configVersion': 2,
          'packages': packages,
        }),
      );

    return flutter;
  }

  test('first scan writes baseline without comparison', () async {
    final flutter = await makeApp();
    final android = p.join(tmp.path, 'android');
    final ios = p.join(tmp.path, 'ios');
    final out = p.join(tmp.path, 'snap.json');

    final result = await checkOta(
      flutterDir: flutter.path,
      androidDir: android,
      iosDir: ios,
      outPath: out,
    );

    expect(result.hasBaseline, isFalse);
    expect(result.otaSupported, isFalse);
    expect(result.changes, isEmpty);
    expect(File(out).existsSync(), isTrue);

    final json = jsonDecode(File(out).readAsStringSync()) as Map<String, dynamic>;
    expect(json['version'], 2);
    expect(json['files'], isA<List>());
    final categories = {
      for (final f in json['files'] as List)
        (f as Map)['category'] as String,
    };
    expect(categories.contains('flutter_dart'), isTrue);
    expect(categories.contains('flutter_assets'), isTrue);
    expect(categories.contains('android'), isTrue);
    expect(categories.contains('ios'), isTrue);
  });

  test('includes dependency dart/assets and treats dep native as blocking', () async {
    final flutter = await makeApp(withDep: true);
    final out = p.join(tmp.path, 'snap.json');

    await checkOta(flutterDir: flutter.path, outPath: out);

    final snap = jsonDecode(File(out).readAsStringSync()) as Map<String, dynamic>;
    final paths = {
      for (final f in snap['files'] as List) (f as Map)['path'] as String,
    };
    expect(paths, contains('lib/main.dart'));
    expect(paths, contains('package:dep_pkg/lib/dep.dart'));
    expect(paths, contains('package:dep_pkg/assets/icon.png'));
    expect(paths, contains('package:dep_pkg/android/src/main/java/P.java'));

    File(p.join(tmp.path, 'dep_pkg', 'lib', 'dep.dart'))
        .writeAsStringSync('class Dep { int x = 1; }');

    final dartResult = await checkOta(flutterDir: flutter.path, outPath: out);
    expect(dartResult.otaSupported, isTrue);
    expect(
      dartResult.patchableChanges.any(
        (c) => c.path == 'package:dep_pkg/lib/dep.dart',
      ),
      isTrue,
    );

    File(p.join(tmp.path, 'dep_pkg', 'android', 'src', 'main', 'java', 'P.java'))
        .writeAsStringSync('class P { void x() {} }');

    final nativeResult = await checkOta(flutterDir: flutter.path, outPath: out);
    expect(nativeResult.otaSupported, isFalse);
    expect(
      nativeResult.blockingChanges.any(
        (c) => c.path.contains('package:dep_pkg/') && c.category == 'flutter_native',
      ),
      isTrue,
    );
  });

  test('no changes against baseline is not OTA supported', () async {
    final flutter = await makeApp();
    final android = p.join(tmp.path, 'android');
    final ios = p.join(tmp.path, 'ios');
    final out = p.join(tmp.path, 'snap.json');

    await checkOta(
      flutterDir: flutter.path,
      androidDir: android,
      iosDir: ios,
      outPath: out,
    );

    final result = await checkOta(
      flutterDir: flutter.path,
      androidDir: android,
      iosDir: ios,
      outPath: out,
      writeSnapshot: false,
    );

    expect(result.hasBaseline, isTrue);
    expect(result.hasChanges, isFalse);
    expect(result.otaSupported, isFalse);
  });

  test('dart/asset-only changes are OTA supported', () async {
    final flutter = await makeApp();
    final android = p.join(tmp.path, 'android');
    final ios = p.join(tmp.path, 'ios');
    final out = p.join(tmp.path, 'snap.json');

    await checkOta(
      flutterDir: flutter.path,
      androidDir: android,
      iosDir: ios,
      outPath: out,
    );

    File(p.join(flutter.path, 'lib', 'main.dart'))
        .writeAsStringSync("void main() { print('x'); }");
    File(p.join(flutter.path, 'assets', 'a.txt')).writeAsStringSync('asset-v2');

    final result = await checkOta(
      flutterDir: flutter.path,
      androidDir: android,
      iosDir: ios,
      outPath: out,
    );

    expect(result.hasBaseline, isTrue);
    expect(result.otaSupported, isTrue);
    expect(result.blockingChanges, isEmpty);
    expect(result.patchableChanges.length, greaterThanOrEqualTo(2));
    expect(
      result.patchableChanges.map((c) => c.category).toSet(),
      containsAll(['flutter_dart', 'flutter_assets']),
    );
  });

  test('android or ios changes are not OTA supported', () async {
    final flutter = await makeApp();
    final android = p.join(tmp.path, 'android');
    final ios = p.join(tmp.path, 'ios');
    final out = p.join(tmp.path, 'snap.json');

    await checkOta(
      flutterDir: flutter.path,
      androidDir: android,
      iosDir: ios,
      outPath: out,
    );

    File(p.join(android, 'app', 'src', 'main', 'kotlin', 'MainActivity.kt'))
        .writeAsStringSync('class MainActivityChanged');

    final androidResult = await checkOta(
      flutterDir: flutter.path,
      androidDir: android,
      iosDir: ios,
      outPath: out,
    );
    expect(androidResult.otaSupported, isFalse);
    expect(androidResult.blockingChanges, isNotEmpty);
    expect(androidResult.blockingChanges.first.category, 'android');

    // Reset baseline after write, then change iOS.
    File(p.join(ios, 'Runner', 'AppDelegate.swift'))
        .writeAsStringSync('import Flutter\n// changed');

    final iosResult = await checkOta(
      flutterDir: flutter.path,
      androidDir: android,
      iosDir: ios,
      outPath: out,
    );
    expect(iosResult.otaSupported, isFalse);
    expect(
      iosResult.blockingChanges.any((c) => c.category == 'ios'),
      isTrue,
    );
  });

  test('--no-write compares without updating snapshot', () async {
    final flutter = await makeApp();
    final out = p.join(tmp.path, 'snap.json');

    await checkOta(flutterDir: flutter.path, outPath: out);
    final before = File(out).readAsStringSync();

    File(p.join(flutter.path, 'lib', 'main.dart'))
        .writeAsStringSync("void main() { /* v2 */ }");

    final result = await checkOta(
      flutterDir: flutter.path,
      outPath: out,
      writeSnapshot: false,
    );

    expect(result.otaSupported, isTrue);
    expect(result.patchableChanges, isNotEmpty);
    expect(File(out).readAsStringSync(), before);
  });
}
