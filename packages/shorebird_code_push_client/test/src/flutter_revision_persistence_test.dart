// flutterpatch: ownership=REPLACE — see flutterpatch docs/cli-shorebird-fork.md
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
  group('flutter revision persistence', () {
    const appId = 'app-id';
    const version = '1.0.0+6';
    const flutterRevision = 'cac82be5c09930db75379e6bde624d28ea6555c5';
    const flutterVersion = '3.41.9';
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

    test('getReleases reads flutter_revision from control_api', () async {
      when(() => httpClient.send(any())).thenAnswer(
        (_) async => http.StreamedResponse(
          Stream.value(
            utf8.encode(
              json.encode({
                'releases': [
                  {
                    'id': 'rel-android',
                    'app_id': appId,
                    'version': version,
                    'platform': 'android',
                    'arch': 'aarch64',
                    'flutter_revision': flutterRevision,
                    'flutter_version': flutterVersion,
                    'created_at': '2026-09-10T00:00:00.000Z',
                  },
                ],
              }),
            ),
          ),
          HttpStatus.ok,
        ),
      );

      final releases = await client.getReleases(appId: appId);
      expect(releases, hasLength(1));
      expect(releases.single.flutterRevision, flutterRevision);
      expect(releases.single.flutterVersion, flutterVersion);
    });

    test('getReleases does not invent flutterpatch placeholder', () async {
      when(() => httpClient.send(any())).thenAnswer(
        (_) async => http.StreamedResponse(
          Stream.value(
            utf8.encode(
              json.encode({
                'releases': [
                  {
                    'id': 'rel-legacy',
                    'app_id': appId,
                    'version': version,
                    'platform': 'android',
                    'arch': 'aarch64',
                    'created_at': '2026-09-10T00:00:00.000Z',
                  },
                ],
              }),
            ),
          ),
          HttpStatus.ok,
        ),
      );

      final releases = await client.getReleases(appId: appId);
      expect(releases.single.flutterRevision, isEmpty);
    });

    test('createReleaseArtifact posts flutter_revision', () async {
      final release = await client.createRelease(
        appId: appId,
        version: version,
        flutterRevision: flutterRevision,
        flutterVersion: flutterVersion,
      );

      final tempDir = Directory.systemTemp.createTempSync();
      final artifact = File('${tempDir.path}/release.bin')
        ..writeAsBytesSync([1, 2, 3, 4]);
      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      final requests = <http.BaseRequest>[];
      when(() => httpClient.send(any())).thenAnswer((invocation) async {
        final request = invocation.positionalArguments.single as http.BaseRequest;
        requests.add(request);
        if (request.url.path.endsWith('/artifacts')) {
          return http.StreamedResponse(
            Stream.value(
              utf8.encode(
                json.encode({'path': 'obj/test.bin', 'hash': 'abcd'}),
              ),
            ),
            HttpStatus.created,
          );
        }
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              json.encode({
                'id': 'rel-1',
                'app_id': appId,
                'version': version,
                'platform': 'android',
                'arch': 'aarch64',
                'flutter_revision': flutterRevision,
                'flutter_version': flutterVersion,
              }),
            ),
          ),
          HttpStatus.created,
        );
      });

      await client.createReleaseArtifact(
        artifactPath: artifact.path,
        appId: appId,
        releaseId: release.id,
        arch: 'aarch64',
        platform: ReleasePlatform.android,
        hash: 'abcd',
        canSideload: true,
        podfileLockHash: null,
      );

      expect(requests, hasLength(2));
      final register = requests.last as http.Request;
      expect(register.url.path, endsWith('/admin/v1/releases'));
      final body = json.decode(register.body) as Map<String, dynamic>;
      expect(body['flutter_revision'], flutterRevision);
      expect(body['flutter_version'], flutterVersion);
    });
  });
}
