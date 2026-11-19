// flutterpatch: ownership=OURS
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';
import 'package:test/test.dart';

class _MockHttpClient extends Mock implements http.Client {}

class _FakeBaseRequest extends Fake implements http.BaseRequest {}

void main() {
  group('CodePushClient chunked upload', () {
    const appId = 'app-id';
    const version = '1.0.0+chunk';
    final hostedUri = Uri.parse('http://control.example');

    late Directory cacheRoot;
    late http.Client httpClient;

    setUpAll(() {
      registerFallbackValue(_FakeBaseRequest());
    });

    setUp(() {
      cacheRoot = Directory.systemTemp.createTempSync('fp_chunk_');
      httpClient = _MockHttpClient();
    });

    tearDown(() {
      if (cacheRoot.existsSync()) {
        cacheRoot.deleteSync(recursive: true);
      }
    });

    http.StreamedResponse jsonResponse(Object body, {int status = 200}) {
      return http.StreamedResponse(
        Stream.value(utf8.encode(json.encode(body))),
        status,
      );
    }

    test('createReleaseArtifact uses /uploads for large files', () async {
      final payload = Uint8List(
        CodePushClient.chunkedUploadThresholdBytes + 100,
      );
      for (var i = 0; i < payload.length; i++) {
        payload[i] = i % 251;
      }
      final hash = sha256.convert(payload).toString();
      const uploadId = 'upload-123';
      const chunkSize = CodePushClient.uploadChunkBytes;
      final totalChunks = (payload.length + chunkSize - 1) ~/ chunkSize;

      final paths = <String>[];
      final methods = <String>[];
      final chunkBodies = <int, List<int>>{};

      when(() => httpClient.send(any())).thenAnswer((invocation) async {
        final request =
            invocation.positionalArguments.first as http.BaseRequest;
        paths.add(request.url.path);
        methods.add(request.method);

        if (request.method == 'POST' &&
            request.url.path.endsWith('/uploads')) {
          return jsonResponse({
            'upload_id': uploadId,
            'chunk_size': chunkSize,
            'size_bytes': payload.length,
            'total_chunks': totalChunks,
          }, status: 201);
        }

        final chunkMatch = RegExp(
          r'/admin/v1/uploads/[^/]+/chunks/(\d+)$',
        ).firstMatch(request.url.path);
        if (request.method == 'PUT' && chunkMatch != null) {
          final index = int.parse(chunkMatch.group(1)!);
          if (request is http.Request) {
            chunkBodies[index] = request.bodyBytes;
          } else if (request is http.StreamedRequest) {
            final bytes = <int>[];
            await for (final c in request.finalize()) {
              bytes.addAll(c);
            }
            chunkBodies[index] = bytes;
          }
          return jsonResponse({
            'upload_id': uploadId,
            'index': index,
            'received_chunks': chunkBodies.length,
            'total_chunks': totalChunks,
            'complete': chunkBodies.length >= totalChunks,
          });
        }

        if (request.method == 'POST' &&
            request.url.path.endsWith('/complete')) {
          return jsonResponse({
            'path': 'obj/chunked.bin',
            'hash': hash,
            'size_bytes': payload.length,
            'upload_id': uploadId,
          }, status: 201);
        }

        if (request.method == 'POST' &&
            request.url.path.endsWith('/releases')) {
          // Ensure registration used the merged artifact_path.
          if (request is http.Request) {
            final body = json.decode(request.body) as Map<String, dynamic>;
            expect(body['artifact_path'], 'obj/chunked.bin');
          }
          return jsonResponse({
            'id': 'rel-1',
            'app_id': appId,
            'version': version,
            'platform': 'android',
            'arch': 'aab',
            'artifact_path': 'obj/chunked.bin',
          }, status: 201);
        }

        fail('unexpected ${request.method} ${request.url.path}');
      });

      final client = CodePushClient(
        httpClient: httpClient,
        hostedUri: hostedUri,
        artifactCacheRoot: cacheRoot,
        uploadRetryBaseDelay: const Duration(milliseconds: 1),
      );
      final release = await client.createRelease(
        appId: appId,
        version: version,
        flutterRevision: 'rev',
      );
      final artifactFile = File(p.join(cacheRoot.path, 'big.aab'))
        ..writeAsBytesSync(payload);

      await client.createReleaseArtifact(
        artifactPath: artifactFile.path,
        appId: appId,
        releaseId: release.id,
        arch: 'aab',
        platform: ReleasePlatform.android,
        hash: hash,
        canSideload: true,
        podfileLockHash: null,
      );

      expect(methods.where((m) => m == 'PUT').length, totalChunks);
      expect(paths.any((p) => p.endsWith('/uploads')), isTrue);
      expect(paths.any((p) => p.endsWith('/complete')), isTrue);
      expect(paths.any((p) => p.endsWith('/artifacts')), isFalse);
      expect(chunkBodies.length, totalChunks);
      expect(chunkBodies[0]!.length, chunkSize);
      expect(
        chunkBodies[totalChunks - 1]!.length,
        payload.length - chunkSize * (totalChunks - 1),
      );

      // Merged bytes equal original payload.
      final merged = <int>[];
      for (var i = 0; i < totalChunks; i++) {
        merged.addAll(chunkBodies[i]!);
      }
      expect(merged, payload);
    });

    test('createPatchArtifact uses artifact_path for large files', () async {
      final payload = Uint8List(
        CodePushClient.chunkedUploadThresholdBytes + 50,
      );
      final hash = sha256.convert(payload).toString();
      const uploadId = 'upload-patch';
      const chunkSize = CodePushClient.uploadChunkBytes;
      final totalChunks = (payload.length + chunkSize - 1) ~/ chunkSize;

      Map<String, dynamic>? patchBody;

      when(() => httpClient.send(any())).thenAnswer((invocation) async {
        final request =
            invocation.positionalArguments.first as http.BaseRequest;
        final path = request.url.path;

        if (request.method == 'POST' && path.endsWith('/uploads')) {
          return jsonResponse({
            'upload_id': uploadId,
            'chunk_size': chunkSize,
            'size_bytes': payload.length,
            'total_chunks': totalChunks,
          }, status: 201);
        }
        if (request.method == 'PUT' && path.contains('/chunks/')) {
          if (request is http.StreamedRequest) {
            await request.finalize().drain<void>();
          }
          return jsonResponse({'ok': true});
        }
        if (request.method == 'POST' && path.endsWith('/complete')) {
          return jsonResponse({
            'path': 'obj/patch-chunked.bin',
            'hash': hash,
            'size_bytes': payload.length,
          }, status: 201);
        }
        if (request.method == 'POST' && path.endsWith('/patches')) {
          if (request is http.Request) {
            patchBody = json.decode(request.body) as Map<String, dynamic>;
          } else if (request is http.StreamedRequest) {
            final bytes = <int>[];
            await for (final c in request.finalize()) {
              bytes.addAll(c);
            }
            patchBody =
                json.decode(utf8.decode(bytes)) as Map<String, dynamic>;
          }
          return jsonResponse({'id': 'patch-uuid', 'number': 1}, status: 201);
        }
        fail('unexpected ${request.method} $path');
      });

      final client = CodePushClient(
        httpClient: httpClient,
        hostedUri: hostedUri,
        artifactCacheRoot: cacheRoot,
        uploadRetryBaseDelay: const Duration(milliseconds: 1),
      );
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
      final diff = File(p.join(cacheRoot.path, 'big.patch'))
        ..writeAsBytesSync(payload);

      await client.createPatchArtifact(
        artifactPath: diff.path,
        appId: appId,
        patchId: patch.id,
        arch: 'aarch64',
        platform: ReleasePlatform.android,
        hash: hash,
      );

      expect(patchBody, isNotNull);
      expect(patchBody!['artifact_path'], 'obj/patch-chunked.bin');
      expect(patchBody!.containsKey('content_base64'), isFalse);
      expect(patchBody!['hash'], hash);
    });

    test('emits per-chunk progress while uploading large files', () async {
      final payload = Uint8List(
        CodePushClient.chunkedUploadThresholdBytes + 100,
      );
      final hash = sha256.convert(payload).toString();
      const uploadId = 'upload-progress';
      const chunkSize = CodePushClient.uploadChunkBytes;
      final totalChunks = (payload.length + chunkSize - 1) ~/ chunkSize;
      final events = <ArtifactUploadProgress>[];

      when(() => httpClient.send(any())).thenAnswer((invocation) async {
        final request =
            invocation.positionalArguments.first as http.BaseRequest;
        final path = request.url.path;
        if (request.method == 'POST' && path.endsWith('/uploads')) {
          return jsonResponse({
            'upload_id': uploadId,
            'chunk_size': chunkSize,
            'size_bytes': payload.length,
            'total_chunks': totalChunks,
          }, status: 201);
        }
        if (request.method == 'PUT' && path.contains('/chunks/')) {
          // Drain streamed body so the client can finish.
          if (request is http.StreamedRequest) {
            await request.finalize().drain<void>();
          }
          return jsonResponse({'ok': true});
        }
        if (request.method == 'POST' && path.endsWith('/complete')) {
          return jsonResponse({
            'path': 'obj/progress.bin',
            'hash': hash,
            'size_bytes': payload.length,
          }, status: 201);
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
        fail('unexpected ${request.method} $path');
      });

      final client = CodePushClient(
        httpClient: httpClient,
        hostedUri: hostedUri,
        artifactCacheRoot: cacheRoot,
        uploadRetryBaseDelay: const Duration(milliseconds: 1),
      );
      final release = await client.createRelease(
        appId: appId,
        version: version,
        flutterRevision: 'rev',
      );
      final artifactFile = File(p.join(cacheRoot.path, 'progress.aab'))
        ..writeAsBytesSync(payload);

      await client.createReleaseArtifact(
        artifactPath: artifactFile.path,
        appId: appId,
        releaseId: release.id,
        arch: 'aab',
        platform: ReleasePlatform.android,
        hash: hash,
        canSideload: true,
        podfileLockHash: null,
        onUploadProgress: events.add,
      );

      final chunked = events.where((e) => e.isChunked).toList();
      expect(chunked, isNotEmpty);
      expect(chunked.first.totalChunks, totalChunks);
      expect(chunked.any((e) => e.chunkIndex == 0), isTrue);
      expect(
        chunked.any(
          (e) =>
              e.chunkIndex == totalChunks - 1 &&
              e.chunkSentBytes == e.chunkTotalBytes,
        ),
        isTrue,
      );
      expect(chunked.last.sentBytes, payload.length);
    });
  });
}
