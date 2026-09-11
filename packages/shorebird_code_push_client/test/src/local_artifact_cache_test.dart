// flutterpatch: ownership=OURS
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_code_push_client/src/local_artifact_cache.dart';
import 'package:test/test.dart';

void main() {
  group(LocalArtifactCache, () {
    late Directory temp;
    late LocalArtifactCache cache;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('fp_artifact_cache_');
      cache = LocalArtifactCache(root: temp);
    });

    tearDown(() {
      if (temp.existsSync()) {
        temp.deleteSync(recursive: true);
      }
    });

    test('write then tryRead returns bytes when meta matches', () async {
      final bytes = utf8.encode('hello cache');
      final hash = sha256.convert(bytes).toString();
      final file = cache.releaseFile(
        appId: 'app',
        version: '1.0.0+1',
        platform: 'android',
        arch: 'aab',
      );

      await cache.write(
        file: file,
        bytes: bytes,
        meta: {'hash': hash, 'size': bytes.length, 'storage_path': 'obj/a.bin'},
      );

      final hit = await cache.tryRead(file);
      expect(hit, isNotNull);
      expect(hit!.bytes, bytes);
      expect(hit.meta['storage_path'], 'obj/a.bin');
    });

    test('tryRead invalidates on size mismatch', () async {
      final file = cache.snapshotFile('snap-1');
      await cache.write(
        file: file,
        bytes: utf8.encode('abc'),
        meta: {'hash': 'nope', 'size': 99},
      );

      expect(await cache.tryRead(file), isNull);
      expect(file.existsSync(), isFalse);
      expect(File('${file.path}.meta.json').existsSync(), isFalse);
    });

    test('tryRead invalidates on hash mismatch', () async {
      final bytes = utf8.encode('payload');
      final file = cache.resourceFile('res-1');
      await cache.write(
        file: file,
        bytes: bytes,
        meta: {
          'hash': '0' * 64,
          'size': bytes.length,
        },
      );

      expect(await cache.tryRead(file), isNull);
      expect(file.existsSync(), isFalse);
    });

    test('tryReadRelease copies a legacy temp hit into root', () async {
      final bytes = utf8.encode('legacy-aab');
      final hash = sha256.convert(bytes).toString();
      const appId = 'legacy-app-id';
      const version = '1.0.0+3';
      final legacyDir = Directory(
        p.join(
          LocalArtifactCache.legacyReleaseCacheRoot.path,
          appId,
          version,
        ),
      );
      legacyDir.createSync(recursive: true);
      final legacyFile = File(p.join(legacyDir.path, 'ios_runner'));
      addTearDown(() {
        final root = Directory(
          p.join(LocalArtifactCache.legacyReleaseCacheRoot.path, appId),
        );
        if (root.existsSync()) {
          root.deleteSync(recursive: true);
        }
      });
      await legacyFile.writeAsBytes(bytes, flush: true);
      await File('${legacyFile.path}.meta.json').writeAsString(
        json.encode({
          'hash': hash,
          'size': bytes.length,
          'storage_path': 'obj/runner.zip',
        }),
        flush: true,
      );

      final hit = await cache.tryReadRelease(
        appId: appId,
        version: version,
        platform: 'ios',
        arch: 'runner',
      );
      expect(hit, isNotNull);
      expect(hit!.bytes, bytes);
      expect(
        hit.file.path,
        cache
            .releaseFile(
              appId: appId,
              version: version,
              platform: 'ios',
              arch: 'runner',
            )
            .path,
      );
    });
  });
}
