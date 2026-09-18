// flutterpatch: ownership=OURS — from meta_ota
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';
import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';
import 'package:test/test.dart';

class _MockHttpClient extends Mock implements http.Client {}

class _FakeBaseRequest extends Fake implements http.BaseRequest {}

void main() {
  group('resources / snapshots / assets', () {
    const appId = 'app-id';
    const version = '1.0.0+1';
    final hostedUri = Uri.parse('http://control.example');

    late http.Client httpClient;
    late CodePushClient client;

    setUpAll(() {
      registerFallbackValue(_FakeBaseRequest());
    });

    setUp(() {
      httpClient = _MockHttpClient();
      client = CodePushClient(
        httpClient: httpClient,
        hostedUri: hostedUri,
      );
    });

    test('uploadResourceSnapshot posts to /admin/v1/resources', () async {
      when(() => httpClient.send(any())).thenAnswer((invocation) async {
        final request =
            invocation.positionalArguments.first as http.Request;
        expect(request.url.path, '/admin/v1/resources');
        expect(request.method, 'POST');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['origin'], 'patch');
        expect(body['patch_number'], 3);
        expect(body['artifact_hash'], 'abc123');
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              jsonEncode({
                'id': 'res-1',
                'number': 1,
                'resource_count': 2,
                'origin': 'patch',
                'patch_number': 3,
                'artifact_hash': 'abc123',
              }),
            ),
          ),
          201,
        );
      });

      final result = await client.uploadResourceSnapshot(
        appId: appId,
        releaseVersion: version,
        contentBytes: utf8.encode('{"resources":[]}'),
        platform: 'android',
        origin: 'patch',
        patchNumber: 3,
        artifactHash: 'abc123',
      );
      expect(result['id'], 'res-1');
      expect(result['number'], 1);
      expect(result['origin'], 'patch');
    });

    test('uploadOtaSnapshot posts to /admin/v1/snapshots', () async {
      when(() => httpClient.send(any())).thenAnswer((invocation) async {
        final request = invocation.positionalArguments.first as http.BaseRequest;
        expect(request.url.path, '/admin/v1/snapshots');
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(jsonEncode({'id': 'snap-1', 'number': 1})),
          ),
          201,
        );
      });

      final result = await client.uploadOtaSnapshot(
        appId: appId,
        releaseVersion: version,
        contentBytes: utf8.encode('{"files":[]}'),
        platform: 'ios',
      );
      expect(result['id'], 'snap-1');
    });

    test('lookupBaselinesByArtifactHash hits by-artifact-hash', () async {
      when(() => httpClient.send(any())).thenAnswer((invocation) async {
        final request = invocation.positionalArguments.first as http.BaseRequest;
        expect(request.url.path, '/admin/v1/baselines/by-artifact-hash');
        expect(request.url.queryParameters['hash'], 'deadbeef');
        expect(request.url.queryParameters['app_id'], appId);
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              jsonEncode({
                'artifact_hash': 'deadbeef',
                'resource': {
                  'origin': 'release',
                  'artifact_hash': 'deadbeef',
                },
                'snapshot': null,
              }),
            ),
          ),
          200,
        );
      });

      final result = await client.lookupBaselinesByArtifactHash(
        artifactHash: 'deadbeef',
        appId: appId,
      );
      expect(result?['resource']['origin'], 'release');
    });

    test('lookupBaselinesByArtifactHash returns null on 404', () async {
      when(() => httpClient.send(any())).thenAnswer(
        (_) async => http.StreamedResponse(const Stream.empty(), 404),
      );
      expect(
        await client.lookupBaselinesByArtifactHash(artifactHash: 'missing'),
        isNull,
      );
    });

    test('uploadContentAddressedAsset posts to /admin/v1/assets', () async {
      when(() => httpClient.send(any())).thenAnswer((invocation) async {
        final request = invocation.positionalArguments.first as http.BaseRequest;
        expect(request.url.path, '/admin/v1/assets');
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              jsonEncode({
                'hash': 'abc',
                'artifact_path': 'obj/sha256/abc.bin',
                'created': true,
                'download_path': '/admin/v1/assets/abc/content',
                'size_bytes': 3,
              }),
            ),
          ),
          201,
        );
      });

      final result = await client.uploadContentAddressedAsset(
        bytes: utf8.encode('hi!'),
        hash: 'abc',
      );
      expect(result['created'], isTrue);
      expect(result['artifact_path'], 'obj/sha256/abc.bin');
    });

    test('getAssetMeta returns null on 404', () async {
      when(() => httpClient.send(any())).thenAnswer(
        (_) async => http.StreamedResponse(const Stream.empty(), 404),
      );
      expect(await client.getAssetMeta('missing'), isNull);
    });

    test('createPatchArtifact includes changed_resources', () async {
      final temp = await Directory.systemTemp.createTemp('fp_patch_');
      final artifact = File('${temp.path}/diff.patch')
        ..writeAsBytesSync(List<int>.filled(64, 1));
      addTearDown(() => temp.delete(recursive: true));

      http.Request? captured;
      when(() => httpClient.send(any())).thenAnswer((invocation) async {
        final request = invocation.positionalArguments.first as http.BaseRequest;
        if (request is http.Request && request.url.path.endsWith('/patches')) {
          captured = request;
          return http.StreamedResponse(
            Stream.value(
              utf8.encode(
                jsonEncode({'id': 'patch-uuid', 'number': 3}),
              ),
            ),
            201,
          );
        }
        // createRelease path not used; still need a response for safety.
        return http.StreamedResponse(
          Stream.value(utf8.encode('{}')),
          200,
        );
      });

      // Seed a release cache via createRelease.
      final release = await client.createRelease(
        appId: appId,
        version: version,
        flutterRevision: 'rev',
      );
      final patch = await client.createPatch(
        appId: appId,
        releaseId: release.id,
        metadata: const {},
        changedResources: [
          {
            'package': 'app',
            'path': 'assets/a.png',
            'hash': 'h',
            'change': 'add',
          },
        ],
        resourceNumber: 2,
      );

      await client.createPatchArtifact(
        artifactPath: artifact.path,
        appId: appId,
        patchId: patch.id,
        arch: 'aarch64',
        platform: ReleasePlatform.android,
        hash: 'deadbeef',
      );

      expect(captured, isNotNull);
      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body['changed_resources'], isA<List>());
      expect(body['resource_number'], 2);
      expect(body['platform'], 'android');
    });

    test('comparePatchResources parses duplicate response', () async {
      when(() => httpClient.send(any())).thenAnswer((invocation) async {
        final request = invocation.positionalArguments.first as http.BaseRequest;
        expect(request.url.path, '/admin/v1/patches/compare');
        expect(request.method, 'POST');
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              jsonEncode({
                'duplicate': true,
                'matching_patch_number': 7,
                'matching_patch_id': 'patch-uuid-7',
              }),
            ),
          ),
          200,
        );
      });

      final result = await client.comparePatchResources(
        appId: appId,
        releaseVersion: version,
        platform: 'android',
        arch: 'aarch64',
        changedResources: [
          {
            'package': 'app',
            'path': 'assets/a.png',
            'hash': 'h',
            'change': 'add',
          },
        ],
      );
      expect(result.duplicate, isTrue);
      expect(result.matchingPatchNumber, 7);
      expect(result.matchingPatchId, 'patch-uuid-7');
    });

    test('comparePatchResources parses non-duplicate response', () async {
      when(() => httpClient.send(any())).thenAnswer(
        (_) async => http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode({'duplicate': false}))),
          200,
        ),
      );

      final result = await client.comparePatchResources(
        appId: appId,
        releaseVersion: version,
        platform: 'android',
        arch: 'aarch64',
        changedResources: const [],
      );
      expect(result.duplicate, isFalse);
      expect(result.matchingPatchNumber, isNull);
    });

    test('createPatchArtifact sends force when requested', () async {
      final temp = await Directory.systemTemp.createTemp('fp_force_');
      final artifact = File('${temp.path}/diff.patch')
        ..writeAsBytesSync(List<int>.filled(32, 2));
      addTearDown(() => temp.delete(recursive: true));

      http.Request? captured;
      when(() => httpClient.send(any())).thenAnswer((invocation) async {
        final request = invocation.positionalArguments.first as http.BaseRequest;
        if (request is http.Request && request.url.path.endsWith('/patches')) {
          captured = request;
          return http.StreamedResponse(
            Stream.value(
              utf8.encode(jsonEncode({'id': 'patch-force', 'number': 4})),
            ),
            201,
          );
        }
        return http.StreamedResponse(
          Stream.value(utf8.encode('{}')),
          200,
        );
      });

      final release = await client.createRelease(
        appId: appId,
        version: version,
        flutterRevision: 'rev',
      );
      final patch = await client.createPatch(
        appId: appId,
        releaseId: release.id,
        metadata: const {},
        changedResources: [
          {
            'package': 'app',
            'path': 'assets/a.png',
            'hash': 'h',
            'change': 'add',
          },
        ],
        force: true,
      );

      await client.createPatchArtifact(
        artifactPath: artifact.path,
        appId: appId,
        patchId: patch.id,
        arch: 'aarch64',
        platform: ReleasePlatform.android,
        hash: 'deadbeef',
      );

      expect(captured, isNotNull);
      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body['force'], isTrue);
      expect(body['changed_resources'], isA<List>());
    });

    test('createPatchArtifact sends whitelist_enabled and unique_ids', () async {
      final temp = await Directory.systemTemp.createTemp('fp_wl_');
      final artifact = File('${temp.path}/diff.patch')
        ..writeAsBytesSync(List<int>.filled(32, 3));
      addTearDown(() => temp.delete(recursive: true));

      http.Request? captured;
      when(() => httpClient.send(any())).thenAnswer((invocation) async {
        final request = invocation.positionalArguments.first as http.BaseRequest;
        if (request is http.Request && request.url.path.endsWith('/patches')) {
          captured = request;
          return http.StreamedResponse(
            Stream.value(
              utf8.encode(jsonEncode({'id': 'patch-wl', 'number': 5})),
            ),
            201,
          );
        }
        return http.StreamedResponse(
          Stream.value(utf8.encode('{}')),
          200,
        );
      });

      final release = await client.createRelease(
        appId: appId,
        version: version,
        flutterRevision: 'rev',
      );
      final patch = await client.createPatch(
        appId: appId,
        releaseId: release.id,
        metadata: const {},
        whitelistEnabled: true,
        uniqueIds: const ['device-a', 'device-b'],
      );

      await client.createPatchArtifact(
        artifactPath: artifact.path,
        appId: appId,
        patchId: patch.id,
        arch: 'aarch64',
        platform: ReleasePlatform.android,
        hash: 'cafebabe',
      );

      expect(captured, isNotNull);
      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body['whitelist_enabled'], isTrue);
      expect(body['unique_ids'], ['device-a', 'device-b']);
    });
  });
}
