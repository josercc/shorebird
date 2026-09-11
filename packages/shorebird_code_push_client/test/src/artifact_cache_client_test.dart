// flutterpatch: ownership=OURS
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';
import 'package:shorebird_code_push_client/src/local_artifact_cache.dart';
import 'package:test/test.dart';

class _MockHttpClient extends Mock implements http.Client {}

class _FakeBaseRequest extends Fake implements http.BaseRequest {}

void main() {
  group('CodePushClient artifact cache', () {
    const appId = 'app-id';
    const version = '1.0.0+3';
    final hostedUri = Uri.parse('http://control.example');

    late Directory cacheRoot;
    late http.Client httpClient;

    setUpAll(() {
      registerFallbackValue(_FakeBaseRequest());
    });

    setUp(() {
      cacheRoot = Directory.systemTemp.createTempSync('fp_client_cache_');
      httpClient = _MockHttpClient();
    });

    tearDown(() {
      if (cacheRoot.existsSync()) {
        cacheRoot.deleteSync(recursive: true);
      }
    });

    CodePushClient newClient(http.Client client) {
      return CodePushClient(
        httpClient: client,
        hostedUri: hostedUri,
        artifactCacheRoot: cacheRoot,
      );
    }

    http.StreamedResponse jsonResponse(Object body, {int status = 200}) {
      return http.StreamedResponse(
        Stream.value(utf8.encode(json.encode(body))),
        status,
      );
    }

    test(
      'getReleaseArtifacts on a new client uses disk cache (no artifact GET)',
      () async {
        when(() => httpClient.send(any())).thenAnswer((invocation) async {
          final request =
              invocation.positionalArguments.first as http.BaseRequest;
          final path = request.url.path;
          if (request.method == 'POST' && path.endsWith('/artifacts')) {
            return jsonResponse({'path': 'obj/aab.bin'}, status: 201);
          }
          if (request.method == 'POST' && path.endsWith('/releases')) {
            return jsonResponse({
              'id': 'rel-1',
              'app_id': appId,
              'version': version,
              'platform': 'android',
              'arch': 'aab',
            }, status: 201);
          }
          if (request.method == 'GET' && path.endsWith('/releases')) {
            return jsonResponse({
              'releases': [
                {
                  'id': 'rel-1',
                  'app_id': appId,
                  'version': version,
                  'platform': 'android',
                  'arch': 'aab',
                  'artifact_path': 'obj/aab.bin',
                },
              ],
            });
          }
          fail('unexpected ${request.method} $path');
        });

        final uploader = newClient(httpClient);
        final release = await uploader.createRelease(
          appId: appId,
          version: version,
          flutterRevision: 'rev',
        );
        final artifactFile = File(p.join(cacheRoot.path, 'upload.aab'))
          ..writeAsBytesSync(utf8.encode('aab-bytes'));
        await uploader.createReleaseArtifact(
          artifactPath: artifactFile.path,
          appId: appId,
          releaseId: release.id,
          arch: 'aab',
          platform: ReleasePlatform.android,
          hash: sha256.convert(utf8.encode('aab-bytes')).toString(),
          canSideload: true,
          podfileLockHash: null,
        );

        final readerHttp = _MockHttpClient();
        final readerRequests = <http.BaseRequest>[];
        when(() => readerHttp.send(any())).thenAnswer((invocation) async {
          final request =
              invocation.positionalArguments.first as http.BaseRequest;
          readerRequests.add(request);
          if (request.url.path.contains('/artifacts/')) {
            fail('should not download artifact: ${request.url}');
          }
          return jsonResponse({
            'releases': [
              {
                'id': 'rel-1',
                'app_id': appId,
                'version': version,
                'platform': 'android',
                'arch': 'aab',
                'artifact_path': 'obj/aab.bin',
              },
            ],
          });
        });

        final reader = newClient(readerHttp);
        final releases = await reader.getReleases(appId: appId);
        final artifacts = await reader.getReleaseArtifacts(
          appId: appId,
          releaseId: releases.single.id,
          arch: 'aab',
          platform: ReleasePlatform.android,
        );

        expect(artifacts, hasLength(1));
        expect(artifacts.single.arch, 'aab');
        expect(Uri.parse(artifacts.single.url).scheme, 'file');
        expect(
          readerRequests.every((r) => !r.url.path.contains('/artifacts/')),
          isTrue,
        );
      },
    );

    test('corrupt release cache re-downloads from control_api', () async {
      when(() => httpClient.send(any())).thenAnswer((invocation) async {
        final request =
            invocation.positionalArguments.first as http.BaseRequest;
        final path = request.url.path;
        if (request.method == 'POST' && path.endsWith('/artifacts')) {
          return jsonResponse({'path': 'obj/aab.bin'}, status: 201);
        }
        if (request.method == 'POST' && path.endsWith('/releases')) {
          return jsonResponse({'id': 'rel-1'}, status: 201);
        }
        fail('unexpected ${request.method} $path');
      });

      final uploader = newClient(httpClient);
      final release = await uploader.createRelease(
        appId: appId,
        version: version,
        flutterRevision: 'rev',
      );
      final artifactFile = File(p.join(cacheRoot.path, 'upload.aab'))
        ..writeAsBytesSync(utf8.encode('aab-bytes'));
      await uploader.createReleaseArtifact(
        artifactPath: artifactFile.path,
        appId: appId,
        releaseId: release.id,
        arch: 'aab',
        platform: ReleasePlatform.android,
        hash: sha256.convert(utf8.encode('aab-bytes')).toString(),
        canSideload: true,
        podfileLockHash: null,
      );

      final cached = LocalArtifactCache(root: cacheRoot).releaseFile(
        appId: appId,
        version: version,
        platform: 'android',
        arch: 'aab',
      );
      cached.writeAsBytesSync(utf8.encode('tampered'));

      final readerHttp = _MockHttpClient();
      var downloaded = false;
      when(() => readerHttp.send(any())).thenAnswer((invocation) async {
        final request =
            invocation.positionalArguments.first as http.BaseRequest;
        final path = request.url.path;
        if (request.method == 'GET' && path.endsWith('/releases')) {
          return jsonResponse({
            'releases': [
              {
                'id': 'rel-1',
                'app_id': appId,
                'version': version,
                'platform': 'android',
                'arch': 'aab',
                'artifact_path': 'obj/aab.bin',
              },
            ],
          });
        }
        if (path.endsWith('/artifacts/obj/aab.bin')) {
          downloaded = true;
          return http.StreamedResponse(
            Stream.value(utf8.encode('fresh-aab')),
            200,
          );
        }
        fail('unexpected ${request.method} $path');
      });

      final reader = newClient(readerHttp);
      final releases = await reader.getReleases(appId: appId);
      final artifacts = await reader.getReleaseArtifacts(
        appId: appId,
        releaseId: releases.single.id,
        arch: 'aab',
        platform: ReleasePlatform.android,
      );

      expect(downloaded, isTrue);
      expect(
        artifacts.single.hash,
        sha256.convert(utf8.encode('fresh-aab')).toString(),
      );
    });

    test('OTA snapshot upload then getContent skips HTTP', () async {
      when(() => httpClient.send(any())).thenAnswer((invocation) async {
        final request =
            invocation.positionalArguments.first as http.BaseRequest;
        expect(request.url.path, '/admin/v1/snapshots');
        return jsonResponse({'id': 'snap-1', 'number': 1}, status: 201);
      });

      final uploader = newClient(httpClient);
      final payload = utf8.encode('{"files":[]}');
      await uploader.uploadOtaSnapshot(
        appId: appId,
        releaseVersion: version,
        contentBytes: payload,
        platform: 'ios',
      );

      final readerHttp = _MockHttpClient();
      when(() => readerHttp.send(any())).thenAnswer((invocation) async {
        fail('should not hit network for cached snapshot');
      });
      final reader = newClient(readerHttp);
      expect(await reader.getOtaSnapshotContent('snap-1'), payload);
    });

    test('resource snapshot getContent caches after first download', () async {
      final payload = utf8.encode('{"resources":[]}');
      var contentGets = 0;
      when(() => httpClient.send(any())).thenAnswer((invocation) async {
        final request =
            invocation.positionalArguments.first as http.BaseRequest;
        expect(request.url.path, '/admin/v1/resources/res-1/content');
        contentGets++;
        return http.StreamedResponse(Stream.value(payload), 200);
      });

      final client = newClient(httpClient);
      expect(await client.getResourceSnapshotContent('res-1'), payload);
      expect(await client.getResourceSnapshotContent('res-1'), payload);
      expect(contentGets, 1);
    });

    test('createPatchArtifact writes patches/ cache keyed by number', () async {
      when(() => httpClient.send(any())).thenAnswer((invocation) async {
        final request =
            invocation.positionalArguments.first as http.BaseRequest;
        if (request.url.path.endsWith('/patches')) {
          return jsonResponse({'id': 'patch-uuid', 'number': 3}, status: 201);
        }
        fail('unexpected ${request.url}');
      });

      final client = newClient(httpClient);
      final release = await client.createRelease(
        appId: appId,
        version: version,
        flutterRevision: 'rev',
      );
      final patch = await client.createPatch(
        appId: appId,
        releaseId: release.id,
        metadata: const {},
      );
      final diff = File(p.join(cacheRoot.path, 'diff.patch'))
        ..writeAsBytesSync(List<int>.filled(32, 7));
      await client.createPatchArtifact(
        artifactPath: diff.path,
        appId: appId,
        patchId: patch.id,
        arch: 'aarch64',
        platform: ReleasePlatform.android,
        hash: 'deadbeef',
      );

      final cached = LocalArtifactCache(root: cacheRoot).patchFile(
        appId: appId,
        version: version,
        platform: 'android',
        arch: 'aarch64',
        number: 3,
      );
      expect(cached.existsSync(), isTrue);
      expect(cached.readAsBytesSync(), List<int>.filled(32, 7));
      final meta =
          json.decode(File('${cached.path}.meta.json').readAsStringSync())
              as Map<String, dynamic>;
      expect(meta['hash'], 'deadbeef');
      expect(meta['patch_id'], 'patch-uuid');
    });
  });
}
