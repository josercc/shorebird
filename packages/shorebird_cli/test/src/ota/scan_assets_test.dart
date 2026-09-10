import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:shorebird_cli/src/ota/scan_assets.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('meta_ota_scan_assets_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('scans app and dependency assets into JSON', () async {
    final app = Directory(p.join(tmp.path, 'my_app'))..createSync();
    final dep = Directory(p.join(tmp.path, 'dep_pkg'))..createSync();

    File(p.join(app.path, 'pubspec.yaml')).writeAsStringSync('''
name: my_app
version: 1.0.0+1
dependencies:
  dep_pkg:
    path: ../dep_pkg
flutter:
  assets:
    - assets/logo.png
    - assets/extra/
''');

    File(p.join(dep.path, 'pubspec.yaml')).writeAsStringSync('''
name: dep_pkg
version: 0.1.0
flutter:
  assets:
    - assets/icon.png
  fonts:
    - family: DepFont
      fonts:
        - asset: fonts/DepFont.ttf
''');

    final logoBytes = [1, 2, 3, 4];
    final iconBytes = [9, 8, 7];
    final extraBytes = [5, 5];
    final fontBytes = [0, 1, 0, 1];

    File(p.join(app.path, 'assets', 'logo.png'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(logoBytes);
    File(p.join(app.path, 'assets', 'extra', 'a.txt'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(extraBytes);
    // Nested file under directory entry should NOT be included (Flutter one-level).
    File(p.join(app.path, 'assets', 'extra', 'nested', 'skip.bin'))
      ..createSync(recursive: true)
      ..writeAsBytesSync([1]);

    File(p.join(dep.path, 'assets', 'icon.png'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(iconBytes);
    File(p.join(dep.path, 'fonts', 'DepFont.ttf'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(fontBytes);

    File(p.join(app.path, 'pubspec.lock')).writeAsStringSync('''
packages:
  dep_pkg:
    dependency: "direct main"
    description:
      path: "../dep_pkg"
      relative: true
    source: path
    version: "0.1.0"
  hosted_icons:
    dependency: transitive
    description:
      name: hosted_icons
      sha256: "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"
      url: "https://pub.dev"
    source: hosted
    version: "1.0.0"
''');

    Directory(p.join(app.path, '.dart_tool')).createSync();
    File(p.join(app.path, '.dart_tool', 'package_config.json')).writeAsStringSync(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'my_app',
            'rootUri': '../',
            'packageUri': 'lib/',
          },
          {
            'name': 'dep_pkg',
            'rootUri': p.toUri(dep.path).toString(),
            'packageUri': 'lib/',
          },
          {
            'name': 'flutter',
            'rootUri': 'flutter:flutter/lib',
            'packageUri': 'lib/',
          },
        ],
      }),
    );

    final out = p.join(tmp.path, 'out.json');
    final result = await scanFlutterAssets(appDir: app.path, outPath: out);

    expect(result.resources.length, 4);
    expect(File(out).existsSync(), isTrue);

    final byKey = {
      for (final r in result.resources) '${r.package}:${r.path}': r,
    };

    expect(byKey['my_app:assets/logo.png']!.size, logoBytes.length);
    expect(
      byKey['my_app:assets/logo.png']!.hash,
      sha256.convert(logoBytes).toString(),
    );
    expect(byKey['my_app:assets/extra/a.txt']!.size, extraBytes.length);
    expect(byKey.containsKey('my_app:assets/extra/nested/skip.bin'), isFalse);

    expect(byKey['dep_pkg:assets/icon.png']!.size, iconBytes.length);
    expect(byKey['dep_pkg:fonts/DepFont.ttf']!.size, fontBytes.length);
    expect(byKey['dep_pkg:assets/icon.png']!.packageHash, isNull);

    final json = jsonDecode(File(out).readAsStringSync()) as Map<String, dynamic>;
    expect(json['count'], 4);
    expect(json['resources'], isA<List>());
  });

  test('skips direct dev packages unless includeDev', () async {
    final app = Directory(p.join(tmp.path, 'app2'))..createSync();
    final dev = Directory(p.join(tmp.path, 'dev_pkg'))..createSync();

    File(p.join(app.path, 'pubspec.yaml')).writeAsStringSync('''
name: app2
flutter:
  assets:
    - a.txt
''');
    File(p.join(app.path, 'a.txt')).writeAsStringSync('app');

    File(p.join(dev.path, 'pubspec.yaml')).writeAsStringSync('''
name: dev_pkg
flutter:
  assets:
    - d.txt
''');
    File(p.join(dev.path, 'd.txt')).writeAsStringSync('dev');

    File(p.join(app.path, 'pubspec.lock')).writeAsStringSync('''
packages:
  dev_pkg:
    dependency: "direct dev"
    description:
      path: "../dev_pkg"
      relative: true
    source: path
    version: "0.0.1"
''');

    Directory(p.join(app.path, '.dart_tool')).createSync();
    File(p.join(app.path, '.dart_tool', 'package_config.json')).writeAsStringSync(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {'name': 'app2', 'rootUri': '../', 'packageUri': 'lib/'},
          {
            'name': 'dev_pkg',
            'rootUri': p.toUri(dev.path).toString(),
            'packageUri': 'lib/',
          },
        ],
      }),
    );

    final without = await scanFlutterAssets(
      appDir: app.path,
      outPath: p.join(tmp.path, 'no_dev.json'),
    );
    expect(without.resources.map((r) => r.package).toSet(), {'app2'});

    final withDev = await scanFlutterAssets(
      appDir: app.path,
      outPath: p.join(tmp.path, 'with_dev.json'),
      includeDev: true,
    );
    expect(withDev.resources.map((r) => r.package).toSet(), {'app2', 'dev_pkg'});
  });

  test('uses hosted package_hash from pubspec.lock', () async {
    final app = Directory(p.join(tmp.path, 'app3'))..createSync();
    final hosted = Directory(p.join(tmp.path, 'hosted_pkg'))..createSync();

    const pkgHash =
        '11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff';

    File(p.join(app.path, 'pubspec.yaml')).writeAsStringSync('''
name: app3
flutter:
  assets: []
''');
    File(p.join(hosted.path, 'pubspec.yaml')).writeAsStringSync('''
name: hosted_pkg
flutter:
  assets:
    - x.bin
''');
    File(p.join(hosted.path, 'x.bin')).writeAsBytesSync([7, 7, 7]);

    File(p.join(app.path, 'pubspec.lock')).writeAsStringSync('''
packages:
  hosted_pkg:
    dependency: transitive
    description:
      name: hosted_pkg
      sha256: "$pkgHash"
      url: "https://pub.dev"
    source: hosted
    version: "2.0.0"
''');

    Directory(p.join(app.path, '.dart_tool')).createSync();
    File(p.join(app.path, '.dart_tool', 'package_config.json')).writeAsStringSync(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {'name': 'app3', 'rootUri': '../', 'packageUri': 'lib/'},
          {
            'name': 'hosted_pkg',
            'rootUri': p.toUri(hosted.path).toString(),
            'packageUri': 'lib/',
          },
        ],
      }),
    );

    final result = await scanFlutterAssets(
      appDir: app.path,
      outPath: p.join(tmp.path, 'hosted.json'),
    );
    expect(result.resources, hasLength(1));
    expect(result.resources.single.package, 'hosted_pkg');
    expect(result.resources.single.packageHash, pkgHash);
    expect(result.resources.single.path, 'x.bin');
    expect(result.resources.single.size, 3);
  });

  test('diffScannedAssets reports add/update/remove', () {
    final baseline = [
      ScannedAsset(
        package: 'app',
        packageHash: null,
        path: 'a.png',
        size: 1,
        hash: 'h1',
      ),
      ScannedAsset(
        package: 'app',
        packageHash: null,
        path: 'gone.png',
        size: 2,
        hash: 'h2',
      ),
    ];
    final next = [
      ScannedAsset(
        package: 'app',
        packageHash: null,
        path: 'a.png',
        size: 9,
        hash: 'h9',
      ),
      ScannedAsset(
        package: 'app',
        packageHash: null,
        path: 'b.png',
        size: 3,
        hash: 'h3',
      ),
    ];
    final changes = diffScannedAssets(baseline: baseline, next: next);
    expect(changes.map((c) => c['change']).toList(), ['update', 'add', 'remove']);
    expect(changes.firstWhere((c) => c['change'] == 'update')['path'], 'a.png');
    expect(changes.firstWhere((c) => c['change'] == 'add')['path'], 'b.png');
    expect(changes.firstWhere((c) => c['change'] == 'remove')['path'], 'gone.png');
  });
}
