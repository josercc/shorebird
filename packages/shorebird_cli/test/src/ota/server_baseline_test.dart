import 'dart:convert';
import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/ota/server_baseline.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';
import 'package:test/test.dart';

import '../mocks.dart';

void main() {
  group('BaselineContentCache', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('baseline_cache_');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('read/write snapshot and resource by id', () {
      final cache = BaselineContentCache(tmp);
      cache.writeSnapshot('snap-1', utf8.encode('{"files":[]}'));
      cache.writeResource('res-1', utf8.encode('{"resources":[]}'));

      expect(
        utf8.decode(cache.readSnapshot('snap-1')!),
        '{"files":[]}',
      );
      expect(
        utf8.decode(cache.readResource('res-1')!),
        '{"resources":[]}',
      );
      expect(cache.readSnapshot('missing'), isNull);
      expect(
        cache.snapshotFile('snap-1').path,
        p.join(tmp.path, 'snapshot', 'snap-1.json'),
      );
    });
  });

  group('fetchServerBaseline cache', () {
    late Directory tmp;
    late MockCodePushClient client;
    late BaselineContentCache cache;

    const appId = 'app-1';
    const version = '1.0.0+1';

    final snapshotJson = json.encode({
      'version': 2,
      'generated_at': '2024-01-01T00:00:00.000Z',
      'paths': {'flutter': '/app'},
      'summary': <String, int>{},
      'files': <Map<String, Object?>>[],
    });
    final resourceJson = json.encode({
      'resources': [
        {
          'package': 'demo',
          'path': 'assets/a.txt',
          'size': 1,
          'hash': 'abc',
        },
      ],
    });

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('baseline_fetch_');
      cache = BaselineContentCache(Directory(p.join(tmp.path, 'baselines')));
      client = MockCodePushClient();

      when(
        () => client.listOtaSnapshots(
          appId: appId,
          releaseVersion: version,
          platform: any(named: 'platform'),
        ),
      ).thenAnswer(
        (_) async => [
          {'id': 'snap-1', 'number': 1, 'rolled_back': false},
        ],
      );
      when(
        () => client.listResourceSnapshots(
          appId: appId,
          releaseVersion: version,
          platform: any(named: 'platform'),
        ),
      ).thenAnswer(
        (_) async => [
          {'id': 'res-1', 'number': 1, 'rolled_back': false},
        ],
      );
      when(() => client.getOtaSnapshotContent('snap-1')).thenAnswer(
        (_) async => utf8.encode(snapshotJson),
      );
      when(() => client.getResourceSnapshotContent('res-1')).thenAnswer(
        (_) async => utf8.encode(resourceJson),
      );
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('downloads once then serves from cache', () async {
      final first = await fetchServerBaseline(
        client: client,
        appId: appId,
        releaseVersion: version,
        cache: cache,
      );
      expect(first.snapshot, isNotNull);
      expect(first.resourceAssets, hasLength(1));

      final second = await fetchServerBaseline(
        client: client,
        appId: appId,
        releaseVersion: version,
        cache: cache,
      );
      expect(second.snapshot, isNotNull);
      expect(second.resourceAssets.single.path, 'assets/a.txt');
      // Content endpoints only called on the first run.
      verify(() => client.getOtaSnapshotContent('snap-1')).called(1);
      verify(() => client.getResourceSnapshotContent('res-1')).called(1);
      // List still runs each time.
      verify(
        () => client.listOtaSnapshots(
          appId: appId,
          releaseVersion: version,
          platform: any(named: 'platform'),
        ),
      ).called(2);
    });

    test('forceRefresh re-downloads content', () async {
      await fetchServerBaseline(
        client: client,
        appId: appId,
        releaseVersion: version,
        cache: cache,
      );
      clearInteractions(client);
      when(
        () => client.listOtaSnapshots(
          appId: appId,
          releaseVersion: version,
          platform: any(named: 'platform'),
        ),
      ).thenAnswer(
        (_) async => [
          {'id': 'snap-1', 'number': 1, 'rolled_back': false},
        ],
      );
      when(
        () => client.listResourceSnapshots(
          appId: appId,
          releaseVersion: version,
          platform: any(named: 'platform'),
        ),
      ).thenAnswer(
        (_) async => [
          {'id': 'res-1', 'number': 1, 'rolled_back': false},
        ],
      );
      when(() => client.getOtaSnapshotContent('snap-1')).thenAnswer(
        (_) async => utf8.encode(snapshotJson),
      );
      when(() => client.getResourceSnapshotContent('res-1')).thenAnswer(
        (_) async => utf8.encode(resourceJson),
      );

      await fetchServerBaseline(
        client: client,
        appId: appId,
        releaseVersion: version,
        cache: cache,
        forceRefresh: true,
      );
      verify(() => client.getOtaSnapshotContent('snap-1')).called(1);
      verify(() => client.getResourceSnapshotContent('res-1')).called(1);
    });

    test('expectedArtifactHash mismatch throws', () async {
      when(
        () => client.listOtaSnapshots(
          appId: appId,
          releaseVersion: version,
          platform: any(named: 'platform'),
        ),
      ).thenAnswer(
        (_) async => [
          {
            'id': 'snap-1',
            'number': 1,
            'rolled_back': false,
            'artifact_hash': 'aaa',
          },
        ],
      );

      expect(
        () => fetchServerBaseline(
          client: client,
          appId: appId,
          releaseVersion: version,
          cache: cache,
          expectedArtifactHash: 'bbb',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('artifact_hash mismatch'),
          ),
        ),
      );
    });
  });
}
