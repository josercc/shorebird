// flutterpatch: ownership=REPLACE — see flutterpatch docs/cli-shorebird-fork.md
//
// Control-plane client rewritten to talk to FlutterPatch control_api
// (`/admin/v1/*`) instead of Shorebird `api.shorebird.dev` (`/api/v1/*`).

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';
import 'package:shorebird_code_push_client/src/local_artifact_cache.dart';
import 'package:shorebird_code_push_client/src/version.dart';
import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';

/// {@template code_push_exception}
/// Base class for all CodePush exceptions.
/// {@endtemplate}
class CodePushException implements Exception {
  /// {@macro code_push_exception}
  const CodePushException({required this.message, this.details});

  /// The message associated with the exception.
  final String message;

  /// The details associated with the exception.
  final String? details;

  @override
  String toString() => '$message${details != null ? '\n$details' : ''}';
}

/// {@template code_push_forbidden_exception}
/// Exception thrown when a 403 response is received.
/// {@endtemplate}
class CodePushForbiddenException extends CodePushException {
  /// {@macro code_push_forbidden_exception}
  CodePushForbiddenException({required super.message, super.details});
}

/// {@template code_push_conflict_exception}
/// Exception thrown when a 409 response is received.
/// {@endtemplate}
class CodePushConflictException extends CodePushException {
  /// {@macro code_push_conflict_exception}
  const CodePushConflictException({required super.message, super.details});
}

/// {@template code_push_not_found_exception}
/// Exception thrown when a 404 response is received.
/// {@endtemplate}
class CodePushNotFoundException extends CodePushException {
  /// {@macro code_push_not_found_exception}
  CodePushNotFoundException({required super.message, super.details});
}

/// {@template code_push_upgrade_required_exception}
/// Exception thrown when a 426 response is received.
/// {@endtemplate}
class CodePushUpgradeRequiredException extends CodePushException {
  /// {@macro code_push_upgrade_required_exception}
  const CodePushUpgradeRequiredException({
    required super.message,
    super.details,
  });
}

/// Result of [CodePushClient.comparePatchResources].
class PatchResourcesCompareResult {
  /// Creates a compare result.
  const PatchResourcesCompareResult({
    required this.duplicate,
    this.matchingPatchNumber,
    this.matchingPatchId,
  });

  /// Whether a published patch already has the same changed_resources.
  final bool duplicate;

  /// Patch number of the matching published patch, if any.
  final int? matchingPatchNumber;

  /// Patch id of the matching published patch, if any.
  final String? matchingPatchId;
}

class _CodePushHttpClient extends http.BaseClient {
  _CodePushHttpClient(this._client, this._headers);

  final http.Client _client;
  final Map<String, String> _headers;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.addAll(_headers);
    return _client.send(request);
  }

  @override
  void close() {
    _client.close();
    super.close();
  }
}

class _PendingPatch {
  _PendingPatch({
    required this.appId,
    required this.releaseId,
    required this.releaseVersion,
    this.changedResources,
    this.resources,
    this.resourceNumber,
    this.configFingerprint,
    this.force = false,
    this.whitelistEnabled,
    this.uniqueIds,
  });

  final String appId;
  final int releaseId;
  final String releaseVersion;
  final List<Map<String, dynamic>>? changedResources;
  /// Full asset inventory for this patch (relative to release baseline).
  final List<Map<String, dynamic>>? resources;
  final int? resourceNumber;
  final String? configFingerprint;
  final bool force;
  final bool? whitelistEnabled;
  final List<String>? uniqueIds;
  final List<String> remotePatchIds = [];
  int? number;
}

class _CachedRelease {
  _CachedRelease({
    required this.appId,
    required this.version,
    required this.flutterRevision,
    this.flutterVersion,
    this.tags,
  });

  final String appId;
  final String version;
  final String flutterRevision;
  final String? flutterVersion;
  final List<String>? tags;
  final Map<String, ReleaseArtifact> artifacts = {};
}

/// Byte-level progress for a streamed control_api artifact download.
class ArtifactDownloadProgress {
  /// Creates a progress event for [label].
  const ArtifactDownloadProgress({
    required this.label,
    required this.receivedBytes,
    this.totalBytes,
  });

  /// Human-readable name for the artifact (e.g. arch `aar`).
  final String label;

  /// Bytes received so far.
  final int receivedBytes;

  /// Total size from `Content-Length`, when the server provides it.
  final int? totalBytes;
}

/// Callback for artifact download byte progress.
typedef ArtifactDownloadProgressCallback =
    void Function(ArtifactDownloadProgress progress);

/// Byte-level progress for a streamed control_api JSON upload.
class ArtifactUploadProgress {
  /// Creates a progress event for [label].
  const ArtifactUploadProgress({
    required this.label,
    required this.sentBytes,
    required this.totalBytes,
  });

  /// Human-readable name for the artifact (e.g. arch `arm64`).
  final String label;

  /// Request-body bytes written so far.
  final int sentBytes;

  /// Total request-body size.
  final int totalBytes;
}

/// Callback for artifact upload byte progress.
typedef ArtifactUploadProgressCallback =
    void Function(ArtifactUploadProgress progress);

/// Dart client for the FlutterPatch control_api (Shorebird CLI-compatible API).
class CodePushClient {
  /// Creates a client pointed at FlutterPatch control_api by default.
  ///
  /// [artifactCacheRoot] defaults to
  /// `{systemTemp}/flutterpatch_artifact_cache`. The CLI injects
  /// `{shorebirdRoot}/bin/cache/flutterpatch`.
  CodePushClient({
    http.Client? httpClient,
    Uri? hostedUri,
    Map<String, String>? customHeaders,
    Directory? artifactCacheRoot,
    @visibleForTesting
    Duration uploadRetryBaseDelay = const Duration(seconds: 1),
  }) : _httpClient = _CodePushHttpClient(httpClient ?? http.Client(), {
         ...standardHeaders,
         ...?customHeaders,
       }),
       hostedUri =
           hostedUri ??
           (throw ArgumentError(
             'hostedUri is required. Set base_url in shorebird.yaml.',
           )),
       _artifactCache = LocalArtifactCache(root: artifactCacheRoot) {
    assert(uploadRetryBaseDelay > Duration.zero);
  }

  /// Standard headers applied to all requests.
  @visibleForTesting
  static const standardHeaders = <String, String>{'x-version': packageVersion};

  /// Default error message.
  @visibleForTesting
  static const unknownErrorMessage = 'An unknown error occurred.';

  final http.Client _httpClient;

  /// Base URI for control_api.
  final Uri hostedUri;

  final LocalArtifactCache _artifactCache;

  Uri get _admin => Uri.parse('$hostedUri/admin/v1');

  int _nextId = 1;
  final Map<int, String> _idToUuid = {};
  final Map<String, int> _uuidToId = {};
  final Map<int, _CachedRelease> _releases = {};
  final Map<int, _PendingPatch> _pendingPatches = {};
  final Map<int, String> _channelNames = {1: 'stable'};

  int _mapUuid(String uuid) {
    final existing = _uuidToId[uuid];
    if (existing != null) return existing;
    final id = _nextId++;
    _uuidToId[uuid] = id;
    _idToUuid[id] = uuid;
    return id;
  }

  String? _uuidOf(int id) => _idToUuid[id];

  Future<Map<String, dynamic>> _json(
    http.Response response,
  ) async {
    if (response.body.isEmpty) return {};
    final decoded = json.decode(response.body);
    if (decoded is Map<String, dynamic>) return decoded;
    return {'data': decoded};
  }

  Never _throw(http.Response response) {
    throw _parseErrorResponse(response.statusCode, response.body);
  }

  /// Login against control_api (no prior auth required).
  Future<Map<String, dynamic>> login({
    required String username,
    required String password,
  }) async {
    final response = await _httpClient.post(
      Uri.parse('$hostedUri/admin/v1/login'),
      headers: {'content-type': 'application/json'},
      body: json.encode({'username': username, 'password': password}),
    );
    if (!response.isSuccess) _throw(response);
    return _json(response);
  }

  /// Fetches the currently logged-in user via `/admin/v1/session`.
  Future<PrivateUser?> getCurrentUser() async {
    final response = await _httpClient.get(Uri.parse('$_admin/session'));
    if (response.statusCode == HttpStatus.unauthorized ||
        response.statusCode == HttpStatus.forbidden) {
      return null;
    }
    if (response.statusCode == HttpStatus.notFound) return null;
    if (!response.isSuccess) _throw(response);

    final jsonBody = await _json(response);
    final username = (jsonBody['username'] as String?) ?? 'admin';
    return PrivateUser(
      id: 1,
      email: username.contains('@') ? username : '$username@flutterpatch.local',
      displayName: username,
      jwtIssuer: hostedUri.toString(),
      hasActiveSubscription: true,
    );
  }

  /// Plan level from overview / session (best-effort).
  Future<String?> getPlanLevel() async {
    final response = await _httpClient.get(Uri.parse('$_admin/overview'));
    if (!response.isSuccess) return null;
    final jsonBody = await _json(response);
    final org = jsonBody['organization'];
    if (org is Map<String, dynamic>) {
      return org['plan_tier'] as String?;
    }
    return jsonBody['plan_tier'] as String? ?? 'selfhost';
  }

  /// Creates a patch record locally; upload happens in [createPatchArtifact].
  ///
  /// Optional [changedResources] / [resources] / [configFingerprint] are
  /// attached to every subsequent [createPatchArtifact] POST for this patch
  /// (Flutter asset OTA). Do **not** pass the release baseline pack number as
  /// [resourceNumber] — the control plane assigns each patch its own pack.
  /// When [force] is true, the create request skips duplicate changed_resources
  /// checks on the control plane (duplicates are allowed by default now).
  Future<Patch> createPatch({
    required String appId,
    required int releaseId,
    required Json metadata,
    List<Map<String, dynamic>>? changedResources,
    List<Map<String, dynamic>>? resources,
    int? resourceNumber,
    String? configFingerprint,
    bool force = false,
    bool? whitelistEnabled,
    List<String>? uniqueIds,
  }) async {
    final release = _releases[releaseId];
    final version = release?.version;
    if (version == null) {
      // Fall back to listing releases from the server.
      final releases = await getReleases(appId: appId);
      final match = releases.where((r) => r.id == releaseId).firstOrNull;
      if (match == null) {
        throw CodePushNotFoundException(
          message: 'Release not found for patch upload',
        );
      }
      _releases[releaseId] = _CachedRelease(
        appId: appId,
        version: match.version,
        flutterRevision: match.flutterRevision,
        flutterVersion: match.flutterVersion,
      );
    }

    final cached = _releases[releaseId]!;
    final id = _nextId++;
    _pendingPatches[id] = _PendingPatch(
      appId: appId,
      releaseId: releaseId,
      releaseVersion: cached.version,
      changedResources: changedResources,
      resources: resources,
      resourceNumber: resourceNumber,
      configFingerprint: configFingerprint,
      force: force,
      whitelistEnabled: whitelistEnabled,
      uniqueIds: uniqueIds,
    );
    return Patch(id: id, number: 0);
  }

  /// Uploads a patch artifact to control_api (`POST /admin/v1/patches`).
  ///
  /// When [number] is set, the server stores the row under that patch number
  /// (used to correlate full-package arches with the code-diff patch).
  /// Set [attachChangedResources] to false for package-level uploads so the
  /// full binary is not tied to Flutter asset change sets.
  Future<void> createPatchArtifact({
    required String artifactPath,
    required String appId,
    required int patchId,
    required String arch,
    required ReleasePlatform platform,
    required String hash,
    String? hashSignature,
    String? podfileLockHash,
    String? packageName,
    List<Map<String, dynamic>>? changedResources,
    List<Map<String, dynamic>>? resources,
    int? resourceNumber,
    String? configFingerprint,
    bool? force,
    bool? whitelistEnabled,
    List<String>? uniqueIds,
    int? number,
    String? notes,
    bool attachChangedResources = true,
    ArtifactUploadProgressCallback? onUploadProgress,
  }) async {
    final pending = _pendingPatches[patchId];
    if (pending == null) {
      throw CodePushNotFoundException(
        message: 'Unknown patch id $patchId — call createPatch first',
      );
    }

    final changed = attachChangedResources
        ? (changedResources ?? pending.changedResources)
        : null;
    final inventory = attachChangedResources
        ? (resources ?? pending.resources)
        : null;
    final resNumber = attachChangedResources
        ? (resourceNumber ?? pending.resourceNumber)
        : null;
    final fingerprint = attachChangedResources
        ? (configFingerprint ?? pending.configFingerprint)
        : null;
    final forceUpload = force ?? pending.force;
    final whitelistOn = whitelistEnabled ?? pending.whitelistEnabled;
    final ids = uniqueIds ?? pending.uniqueIds;

    final bytes = await File(artifactPath).readAsBytes();
    final body = <String, dynamic>{
      'app_id': appId,
      'release_version': pending.releaseVersion,
      'platform': platform.name,
      'arch': arch,
      'hash': hash,
      'content_base64': base64Encode(bytes),
      if (hashSignature != null) 'hash_signature': hashSignature,
      'channel': 'stable',
      if (packageName != null && packageName.isNotEmpty)
        'package_name': packageName,
      // Always send when resolved (including empty list) so each patch owns
      // an explicit resource table vs the release baseline.
      if (changed != null) 'changed_resources': changed,
      if (inventory != null) 'resources': inventory,
      if (resNumber != null) 'resource_number': resNumber,
      if (fingerprint != null && fingerprint.isNotEmpty)
        'config_fingerprint': fingerprint,
      if (forceUpload) 'force': true,
      if (whitelistOn != null) 'whitelist_enabled': whitelistOn,
      if (ids != null) 'unique_ids': ids,
      if (number != null) 'number': number,
      if (notes != null && notes.isNotEmpty) 'notes': notes,
    };

    final response = await _postJson(
      Uri.parse('$_admin/patches'),
      body,
      progressLabel: arch,
      onUploadProgress: onUploadProgress,
    );
    if (!response.isSuccess) _throw(response);

    final created = await _json(response);
    final uuid = created['id'] as String;
    pending.remotePatchIds.add(uuid);
    _mapUuid(uuid);
    // Point the synthetic patch id at the first uploaded remote patch.
    _idToUuid.putIfAbsent(patchId, () => uuid);
    _uuidToId[uuid] = patchId;
    pending.number = (created['number'] as num?)?.toInt() ?? pending.number;
    final resolvedNumber = number ?? pending.number;
    if (resolvedNumber != null) {
      await _artifactCache.write(
        file: _artifactCache.patchFile(
          appId: appId,
          version: pending.releaseVersion,
          platform: platform.name,
          arch: arch,
          number: resolvedNumber,
        ),
        bytes: bytes,
        meta: {
          'hash': hash,
          'size': bytes.length,
          'patch_id': uuid,
        },
      );
    }
  }

  /// Downloads a stored admin artifact by relative [artifactPath].
  ///
  /// Hits [LocalArtifactCache.adminArtifactFile] when present; otherwise
  /// streams from control_api and writes the cache entry. The returned [File]
  /// is the durable cache path (not a temp copy).
  Future<File> downloadAdminArtifact(
    String artifactPath, {
    ArtifactDownloadProgressCallback? onDownloadProgress,
  }) async {
    final path = artifactPath.trim();
    if (path.isEmpty) {
      throw ArgumentError.value(
        artifactPath,
        'artifactPath',
        'must be non-empty',
      );
    }
    final label = path.split('/').last;
    final cacheFile = _artifactCache.adminArtifactFile(path);
    final hit = await _artifactCache.tryRead(cacheFile);
    if (hit != null) {
      onDownloadProgress?.call(
        ArtifactDownloadProgress(
          label: label,
          receivedBytes: hit.bytes.length,
          totalBytes: hit.bytes.length,
        ),
      );
      return hit.file;
    }

    final bytes = await _downloadAdminArtifact(
      path,
      label: label,
      onDownloadProgress: onDownloadProgress,
    );
    await _writeAdminArtifactCache(storagePath: path, bytes: bytes);
    return cacheFile;
  }

  /// Uploads a full package patch artifact (aar / xcframework / supplement)
  /// without attaching Flutter asset change sets.
  ///
  /// Used after the code-diff patch is published so `--from-release` can
  /// promote the patched binary by [hash].
  Future<Map<String, dynamic>> uploadPatchPackageArtifact({
    required String appId,
    required String releaseVersion,
    required ReleasePlatform platform,
    required String arch,
    required String artifactPath,
    required String hash,
    required int number,
    String? notes,
    ArtifactUploadProgressCallback? onUploadProgress,
  }) async {
    final bytes = await File(artifactPath).readAsBytes();
    final response = await _postJson(
      Uri.parse('$_admin/patches'),
      {
        'app_id': appId,
        'release_version': releaseVersion,
        'platform': platform.name,
        'arch': arch,
        'hash': hash,
        'content_base64': base64Encode(bytes),
        'channel': 'stable',
        'number': number,
        'force': true,
        if (notes != null && notes.isNotEmpty) 'notes': notes,
      },
      progressLabel: arch,
      onUploadProgress: onUploadProgress,
    );
    if (!response.isSuccess) _throw(response);
    final created = await _json(response);
    final storagePath =
        (created['artifact_path'] as String?)?.trim() ??
        (created['path'] as String?)?.trim() ??
        '';
    await _artifactCache.write(
      file: _artifactCache.patchFile(
        appId: appId,
        version: releaseVersion,
        platform: platform.name,
        arch: arch,
        number: number,
      ),
      bytes: bytes,
      meta: {
        'hash': hash,
        'size': bytes.length,
        'patch_id': created['id'],
        if (storagePath.isNotEmpty) 'storage_path': storagePath,
      },
    );
    if (storagePath.isNotEmpty) {
      await _writeAdminArtifactCache(
        storagePath: storagePath,
        bytes: bytes,
        hash: hash,
      );
    }
    return created;
  }

  /// Compares candidate [changedResources] against published patches for the
  /// given release/platform/arch (`POST /admin/v1/patches/compare`).
  Future<PatchResourcesCompareResult> comparePatchResources({
    required String appId,
    required String releaseVersion,
    required String platform,
    required String arch,
    required List<Map<String, dynamic>> changedResources,
  }) async {
    final response = await _httpClient.post(
      Uri.parse('$_admin/patches/compare'),
      headers: {'content-type': 'application/json'},
      body: json.encode({
        'app_id': appId,
        'release_version': releaseVersion,
        'platform': platform,
        'arch': arch,
        'changed_resources': changedResources,
      }),
    );
    if (!response.isSuccess) _throw(response);
    final body = await _json(response);
    return PatchResourcesCompareResult(
      duplicate: body['duplicate'] == true,
      matchingPatchNumber: (body['matching_patch_number'] as num?)?.toInt(),
      matchingPatchId: body['matching_patch_id'] as String?,
    );
  }

  // ---------------------------------------------------------------------------
  // Resources / snapshots / content-addressed assets (from meta_ota)
  // flutterpatch: ownership=OURS — from meta_ota
  // ---------------------------------------------------------------------------

  /// Uploads a version resource snapshot (`POST /admin/v1/resources`).
  ///
  /// [origin] is `release` (default) or `patch`. When `patch`, [patchNumber]
  /// is required. [artifactHash] is the full binary sha256 used for by-hash
  /// lookup (not the JSON content hash).
  Future<Map<String, dynamic>> uploadResourceSnapshot({
    required String appId,
    required String releaseVersion,
    required List<int> contentBytes,
    String? platform,
    String? packageName,
    String channel = 'stable',
    String? notes,
    int? resourceCount,
    String origin = 'release',
    int? patchNumber,
    String? artifactHash,
    ArtifactUploadProgressCallback? onUploadProgress,
  }) async {
    final hash = sha256.convert(contentBytes).toString();
    final response = await _postJson(
      Uri.parse('$_admin/resources'),
      {
        'app_id': appId,
        'release_version': releaseVersion,
        'channel': channel,
        'content_base64': base64Encode(contentBytes),
        'hash': hash,
        'origin': origin,
        if (platform != null && platform.isNotEmpty) 'platform': platform,
        if (packageName != null && packageName.isNotEmpty)
          'package_name': packageName,
        if (resourceCount != null) 'resource_count': resourceCount,
        if (notes != null && notes.isNotEmpty) 'notes': notes,
        if (patchNumber != null) 'patch_number': patchNumber,
        if (artifactHash != null && artifactHash.isNotEmpty)
          'artifact_hash': artifactHash,
      },
      progressLabel: 'resource snapshot',
      onUploadProgress: onUploadProgress,
    );
    if (!response.isSuccess) _throw(response);
    final created = await _json(response);
    final id = created['id']?.toString();
    if (id != null && id.isNotEmpty) {
      await _artifactCache.write(
        file: _artifactCache.resourceFile(id),
        bytes: contentBytes,
        meta: {
          'hash': hash,
          'size': contentBytes.length,
          'app_id': appId,
          'version': releaseVersion,
          if (platform != null && platform.isNotEmpty) 'platform': platform,
          'number': created['number'],
          'origin': origin,
          if (patchNumber != null) 'patch_number': patchNumber,
          if (artifactHash != null && artifactHash.isNotEmpty)
            'artifact_hash': artifactHash,
        },
      );
    }
    return created;
  }

  Future<List<Map<String, dynamic>>> listResourceSnapshots({
    required String appId,
    String? releaseVersion,
    String? platform,
    String? artifactHash,
  }) async {
    final response = await _httpClient.get(
      Uri.parse('$_admin/resources').replace(
        queryParameters: {
          'app_id': appId,
          if (releaseVersion != null) 'release_version': releaseVersion,
          if (platform != null && platform.isNotEmpty) 'platform': platform,
          if (artifactHash != null && artifactHash.isNotEmpty)
            'artifact_hash': artifactHash,
        },
      ),
    );
    if (!response.isSuccess) _throw(response);
    final body = await _json(response);
    final list = body['resources'] as List? ?? const [];
    return list
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  /// Downloads resource snapshot JSON bytes by id.
  Future<List<int>> getResourceSnapshotContent(
    String id, {
    ArtifactDownloadProgressCallback? onDownloadProgress,
  }) async {
    final cached = await _artifactCache.tryRead(
      _artifactCache.resourceFile(id),
    );
    if (cached != null) return cached.bytes;

    final bytes = await _downloadBytes(
      Uri.parse('$_admin/resources/$id/content'),
      label: 'resource',
      onDownloadProgress: onDownloadProgress,
    );
    await _artifactCache.write(
      file: _artifactCache.resourceFile(id),
      bytes: bytes,
      meta: {
        'hash': sha256.convert(bytes).toString(),
        'size': bytes.length,
      },
    );
    return bytes;
  }

  /// Uploads an OTA eligibility snapshot (`POST /admin/v1/snapshots`).
  ///
  /// See [uploadResourceSnapshot] for [origin] / [patchNumber] / [artifactHash].
  Future<Map<String, dynamic>> uploadOtaSnapshot({
    required String appId,
    required String releaseVersion,
    required List<int> contentBytes,
    String? platform,
    String? packageName,
    String channel = 'stable',
    String? notes,
    int? fileCount,
    String origin = 'release',
    int? patchNumber,
    String? artifactHash,
    ArtifactUploadProgressCallback? onUploadProgress,
  }) async {
    final hash = sha256.convert(contentBytes).toString();
    final response = await _postJson(
      Uri.parse('$_admin/snapshots'),
      {
        'app_id': appId,
        'release_version': releaseVersion,
        'channel': channel,
        'content_base64': base64Encode(contentBytes),
        'hash': hash,
        'origin': origin,
        if (platform != null && platform.isNotEmpty) 'platform': platform,
        if (packageName != null && packageName.isNotEmpty)
          'package_name': packageName,
        if (fileCount != null) 'file_count': fileCount,
        if (notes != null && notes.isNotEmpty) 'notes': notes,
        if (patchNumber != null) 'patch_number': patchNumber,
        if (artifactHash != null && artifactHash.isNotEmpty)
          'artifact_hash': artifactHash,
      },
      progressLabel: 'OTA snapshot',
      onUploadProgress: onUploadProgress,
    );
    if (!response.isSuccess) _throw(response);
    final created = await _json(response);
    final id = created['id']?.toString();
    if (id != null && id.isNotEmpty) {
      await _artifactCache.write(
        file: _artifactCache.snapshotFile(id),
        bytes: contentBytes,
        meta: {
          'hash': hash,
          'size': contentBytes.length,
          'app_id': appId,
          'version': releaseVersion,
          if (platform != null && platform.isNotEmpty) 'platform': platform,
          'number': created['number'],
          'origin': origin,
          if (patchNumber != null) 'patch_number': patchNumber,
          if (artifactHash != null && artifactHash.isNotEmpty)
            'artifact_hash': artifactHash,
        },
      );
    }
    return created;
  }

  /// Lists OTA snapshots for an app/version.
  Future<List<Map<String, dynamic>>> listOtaSnapshots({
    required String appId,
    String? releaseVersion,
    String? platform,
    String? artifactHash,
  }) async {
    final response = await _httpClient.get(
      Uri.parse('$_admin/snapshots').replace(
        queryParameters: {
          'app_id': appId,
          if (releaseVersion != null) 'release_version': releaseVersion,
          if (platform != null && platform.isNotEmpty) 'platform': platform,
          if (artifactHash != null && artifactHash.isNotEmpty)
            'artifact_hash': artifactHash,
        },
      ),
    );
    if (!response.isSuccess) _throw(response);
    final body = await _json(response);
    final list = body['snapshots'] as List? ?? const [];
    return list
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  /// Downloads OTA snapshot JSON bytes by id.
  Future<List<int>> getOtaSnapshotContent(
    String id, {
    ArtifactDownloadProgressCallback? onDownloadProgress,
  }) async {
    final cached = await _artifactCache.tryRead(
      _artifactCache.snapshotFile(id),
    );
    if (cached != null) return cached.bytes;

    final bytes = await _downloadBytes(
      Uri.parse('$_admin/snapshots/$id/content'),
      label: 'snapshot',
      onDownloadProgress: onDownloadProgress,
    );
    await _artifactCache.write(
      file: _artifactCache.snapshotFile(id),
      bytes: bytes,
      meta: {
        'hash': sha256.convert(bytes).toString(),
        'size': bytes.length,
      },
    );
    return bytes;
  }

  /// Looks up resource + snapshot baselines (+ optional full package patch)
  /// by full binary [artifactHash].
  ///
  /// Returns `null` when the control plane responds 404.
  Future<Map<String, dynamic>?> lookupBaselinesByArtifactHash({
    required String artifactHash,
    String? appId,
    String? platform,
  }) async {
    final hash = artifactHash.trim();
    if (hash.isEmpty) {
      throw ArgumentError.value(
        artifactHash,
        'artifactHash',
        'must be non-empty',
      );
    }
    final response = await _httpClient.get(
      Uri.parse('$_admin/baselines/by-artifact-hash').replace(
        queryParameters: {
          'hash': hash,
          if (appId != null && appId.isNotEmpty) 'app_id': appId,
          if (platform != null && platform.isNotEmpty) 'platform': platform,
        },
      ),
    );
    if (response.statusCode == HttpStatus.notFound) return null;
    if (!response.isSuccess) _throw(response);
    return _json(response);
  }

  /// Looks up a content-addressed asset by sha256. Returns null on 404.
  Future<Map<String, dynamic>?> getAssetMeta(String hash) async {
    final response = await _httpClient.get(Uri.parse('$_admin/assets/$hash'));
    if (response.statusCode == HttpStatus.notFound) return null;
    if (!response.isSuccess) _throw(response);
    return _json(response);
  }

  /// Uploads a content-addressed asset (`POST /admin/v1/assets`).
  /// Identical hashes are deduped server-side (`created: false`).
  Future<Map<String, dynamic>> uploadContentAddressedAsset({
    required List<int> bytes,
    String? hash,
    ArtifactUploadProgressCallback? onUploadProgress,
  }) async {
    final computed = hash ?? sha256.convert(bytes).toString();
    final response = await _postJson(
      Uri.parse('$_admin/assets'),
      {
        'content_base64': base64Encode(bytes),
        'hash': computed,
      },
      progressLabel: 'asset',
      onUploadProgress: onUploadProgress,
    );
    if (!response.isSuccess) _throw(response);
    return _json(response);
  }

  /// Registers a release (metadata). Per-arch rows are created in
  /// [createReleaseArtifact].
  Future<Release> createRelease({
    required String appId,
    required String version,
    required String flutterRevision,
    String? flutterVersion,
    String? displayName,
    List<String>? tags,
  }) async {
    final id = _nextId++;
    _releases[id] = _CachedRelease(
      appId: appId,
      version: version,
      flutterRevision: flutterRevision,
      flutterVersion: flutterVersion,
      tags: tags,
    );
    final now = DateTime.now().toUtc();
    return Release(
      id: id,
      appId: appId,
      version: version,
      flutterRevision: flutterRevision,
      flutterVersion: flutterVersion,
      displayName: displayName,
      platformStatuses: const {},
      createdAt: now,
      updatedAt: now,
    );
  }

  /// Attach [tags] to a locally cached release so subsequent
  /// [createReleaseArtifact] POSTs include them. Also PATCHes the control
  /// plane so existing releases get labeled without re-upload.
  Future<void> setReleaseTags({
    required String appId,
    required int releaseId,
    required List<String> tags,
    String? releaseVersion,
  }) async {
    final cached = _releases[releaseId];
    if (cached != null) {
      final next = _CachedRelease(
        appId: cached.appId,
        version: cached.version,
        flutterRevision: cached.flutterRevision,
        flutterVersion: cached.flutterVersion,
        tags: tags,
      );
      next.artifacts.addAll(cached.artifacts);
      _releases[releaseId] = next;
    }
    final version = (cached?.version ?? releaseVersion)?.trim() ?? '';
    if (version.isEmpty) {
      throw CodePushException(
        message: 'Cannot set tags: unknown release version for id $releaseId',
      );
    }
    final response = await _httpClient.patch(
      Uri.parse(
        '$_admin/releases?app_id=${Uri.encodeComponent(appId)}'
        '&version=${Uri.encodeComponent(version)}',
      ),
      headers: {'content-type': 'application/json'},
      body: json.encode({'tags': tags}),
    );
    if (!response.isSuccess) _throw(response);
  }

  /// No-op on control_api (releases are active once registered).
  Future<void> updateReleaseStatus({
    required String appId,
    required int releaseId,
    required ReleasePlatform platform,
    required ReleaseStatus status,
    Json? metadata,
  }) async {
    final cached = _releases[releaseId];
    if (cached == null) return;
    // Keep local status map for getReleases shape if needed later.
  }

  /// Uploads release binary to control_api and caches a local `file://` URL
  /// so subsequent `patch` can diff without Shorebird GCS.
  Future<void> createReleaseArtifact({
    required String artifactPath,
    required String appId,
    required int releaseId,
    required String arch,
    required ReleasePlatform platform,
    required String hash,
    required bool canSideload,
    required String? podfileLockHash,
    String? packageName,
    ArtifactUploadProgressCallback? onUploadProgress,
  }) async {
    final cached = _releases[releaseId];
    if (cached == null) {
      throw CodePushNotFoundException(
        message: 'Unknown release id $releaseId',
      );
    }

    final bytes = await File(artifactPath).readAsBytes();
    final upload = await _postJson(
      Uri.parse('$_admin/artifacts'),
      {'content_base64': base64Encode(bytes)},
      progressLabel: arch,
      onUploadProgress: onUploadProgress,
    );
    if (!upload.isSuccess) _throw(upload);
    final uploaded = await _json(upload);
    final storagePath = uploaded['path'] as String? ?? '';

    final register = await _httpClient.post(
      Uri.parse('$_admin/releases'),
      headers: {'content-type': 'application/json'},
      body: json.encode({
        'app_id': appId,
        'version': cached.version,
        'platform': platform.name,
        'arch': arch,
        if (storagePath.isNotEmpty) 'artifact_path': storagePath,
        if (packageName != null && packageName.isNotEmpty)
          'package_name': packageName,
        if (cached.flutterRevision.isNotEmpty)
          'flutter_revision': cached.flutterRevision,
        if (cached.flutterVersion != null && cached.flutterVersion!.isNotEmpty)
          'flutter_version': cached.flutterVersion,
        if (cached.tags != null && cached.tags!.isNotEmpty) 'tags': cached.tags,
      }),
    );
    if (!register.isSuccess) _throw(register);
    final releaseRow = await _json(register);
    final uuid = releaseRow['id'] as String?;
    if (uuid != null) {
      _idToUuid[releaseId] = uuid;
      _uuidToId[uuid] = releaseId;
    }

    final resolvedHash = hash.isNotEmpty
        ? hash
        : sha256.convert(bytes).toString();
    final cachedFile = await _writeReleaseArtifactCache(
      appId: appId,
      version: cached.version,
      platform: platform,
      arch: arch,
      bytes: bytes,
      hash: resolvedHash,
      storagePath: storagePath,
    );

    final artifact = ReleaseArtifact(
      id: _nextId++,
      releaseId: releaseId,
      arch: arch,
      platform: platform,
      hash: resolvedHash,
      size: bytes.length,
      url: cachedFile.uri.toString(),
      canSideload: canSideload,
      podfileLockHash: podfileLockHash,
    );
    cached.artifacts['${platform.name}:$arch'] = artifact;
  }

  Future<PrivateUser> createUser({required String name}) async {
    // control_api has no public create-user for CLI; return session-shaped user.
    return PrivateUser(
      id: 1,
      email: '$name@flutterpatch.local',
      displayName: name,
      jwtIssuer: hostedUri.toString(),
      hasActiveSubscription: true,
    );
  }

  Future<App> createApp({
    required int organizationId,
    required String displayName,
  }) async {
    final response = await _httpClient.post(
      Uri.parse('$_admin/apps'),
      headers: {'content-type': 'application/json'},
      body: json.encode({'name': displayName}),
    );
    if (!response.isSuccess) _throw(response);
    final body = await _json(response);
    return App(
      id: body['id'] as String,
      displayName: (body['name'] as String?) ?? displayName,
    );
  }

  Future<Channel> createChannel({
    required String appId,
    required String channel,
  }) async {
    final id = channel == 'stable'
        ? 1
        : _channelNames.entries
                  .where((e) => e.value == channel)
                  .map((e) => e.key)
                  .firstOrNull ??
              _nextId++;
    _channelNames[id] = channel;
    return Channel(id: id, appId: appId, name: channel);
  }

  Future<void> deleteApp({required String appId}) async {
    final response = await _httpClient.delete(Uri.parse('$_admin/apps/$appId'));
    if (!response.isSuccess) _throw(response);
  }

  Future<void> updateApp({
    required String appId,
    required String displayName,
  }) async {
    final response = await _httpClient.patch(
      Uri.parse('$_admin/apps/$appId'),
      headers: {'content-type': 'application/json'},
      body: json.encode({'name': displayName}),
    );
    if (!response.isSuccess) _throw(response);
  }

  Future<void> transferApp({
    required int organizationId,
    required String appId,
  }) async {
    throw const CodePushException(
      message:
          'App transfer is not supported by FlutterPatch control_api. '
          'Use the dashboard or contact your platform admin.',
    );
  }

  Future<void> deleteChannel({
    required String appId,
    required int channelId,
  }) async {
    throw const CodePushException(
      message:
          'Channels are not first-class resources on FlutterPatch. '
          'Pass channel when promoting a patch.',
    );
  }

  Future<List<AppMetadata>> getApps() async {
    final response = await _httpClient.get(Uri.parse('$_admin/apps'));
    if (!response.isSuccess) _throw(response);
    final body = await _json(response);
    final apps = (body['apps'] as List? ?? const []);
    final now = DateTime.now().toUtc();
    return apps.map((raw) {
      final m = raw as Map<String, dynamic>;
      return AppMetadata(
        appId: m['id'] as String,
        displayName: (m['name'] as String?) ?? '',
        createdAt: DateTime.tryParse('${m['created_at'] ?? ''}') ?? now,
        updatedAt: DateTime.tryParse('${m['updated_at'] ?? ''}') ?? now,
      );
    }).toList();
  }

  Future<List<Channel>> getChannels({required String appId}) async {
    return [
      for (final e in _channelNames.entries)
        Channel(id: e.key, appId: appId, name: e.value),
    ];
  }

  Future<List<Release>> getReleases({
    required String appId,
    bool sideloadableOnly = false,
  }) async {
    final response = await _httpClient.get(
      Uri.parse('$_admin/releases').replace(queryParameters: {'app_id': appId}),
    );
    if (!response.isSuccess) _throw(response);
    final body = await _json(response);
    final rows = (body['releases'] as List? ?? const []);

    // Group by version → one Shorebird-shaped Release.
    final byVersion = <String, List<Map<String, dynamic>>>{};
    for (final raw in rows) {
      final m = raw as Map<String, dynamic>;
      final version = m['version'] as String? ?? '';
      byVersion.putIfAbsent(version, () => []).add(m);
    }

    final result = <Release>[];
    for (final entry in byVersion.entries) {
      final hasSideloadable = entry.value.any((row) {
        final arch = row['arch'] as String?;
        return arch != null && _isSideloadableArch(arch);
      });
      if (sideloadableOnly && !hasSideloadable) continue;

      final first = entry.value.first;
      final uuid = first['id'] as String? ?? entry.key;
      final id = _mapUuid('release:$appId:${entry.key}:$uuid');
      final platformStatuses = <ReleasePlatform, ReleaseStatus>{};
      for (final row in entry.value) {
        final platformName = row['platform'] as String?;
        if (platformName == null) continue;
        try {
          platformStatuses[ReleasePlatform.fromJson(platformName)] =
              ReleaseStatus.active;
        } on FormatException {
          // ignore unknown platforms
        }
      }
      final created =
          DateTime.tryParse('${first['created_at'] ?? ''}') ??
          DateTime.now().toUtc();
      final cached = _releases[id];
      final apiRevision = entry.value
          .map((row) => (row['flutter_revision'] as String?)?.trim())
          .whereType<String>()
          .where((r) => r.isNotEmpty && r != 'flutterpatch')
          .firstOrNull;
      final apiFlutterVersion = entry.value
          .map((row) => (row['flutter_version'] as String?)?.trim())
          .whereType<String>()
          .where((v) => v.isNotEmpty)
          .firstOrNull;
      final cachedRevision = cached?.flutterRevision.trim() ?? '';
      final cachedRevisionKnown =
          cachedRevision.isNotEmpty && cachedRevision != 'flutterpatch';
      final resolvedRevision = cachedRevisionKnown
          ? cachedRevision
          : (apiRevision ?? '');
      final resolvedFlutterVersion =
          cached?.flutterVersion ?? apiFlutterVersion;
      final release = Release(
        id: id,
        appId: appId,
        version: entry.key,
        flutterRevision: resolvedRevision,
        flutterVersion: resolvedFlutterVersion,
        platformStatuses: platformStatuses,
        createdAt: created,
        updatedAt: created,
      );
      final nextCache = _CachedRelease(
        appId: appId,
        version: entry.key,
        flutterRevision: release.flutterRevision,
        flutterVersion: release.flutterVersion,
        tags: cached?.tags,
      );
      // Preserve any artifacts already cached for this synthetic id.
      if (cached != null) {
        nextCache.artifacts.addAll(cached.artifacts);
      }
      _releases[id] = nextCache;
      result.add(release);
    }

    // Include locally created releases not yet listed (same session).
    for (final e in _releases.entries) {
      if (e.value.appId == appId && result.every((r) => r.id != e.key)) {
        final hasSideloadable = e.value.artifacts.values.any(
          (a) => a.canSideload,
        );
        if (sideloadableOnly && !hasSideloadable) continue;
        final now = DateTime.now().toUtc();
        result.add(
          Release(
            id: e.key,
            appId: appId,
            version: e.value.version,
            flutterRevision: e.value.flutterRevision,
            flutterVersion: e.value.flutterVersion,
            platformStatuses: {
              for (final a in e.value.artifacts.values)
                a.platform: ReleaseStatus.active,
            },
            createdAt: now,
            updatedAt: now,
          ),
        );
      }
    }
    return result;
  }

  Future<List<ReleasePatch>> getPatches({
    required String appId,
    required int releaseId,
  }) async {
    final cached = _releases[releaseId];
    final version = cached?.version;
    final response = await _httpClient.get(
      Uri.parse('$_admin/patches').replace(
        queryParameters: {
          'app_id': appId,
          if (version != null) 'release_version': version,
        },
      ),
    );
    if (!response.isSuccess) _throw(response);
    final body = await _json(response);
    final rows = (body['patches'] as List? ?? const []);
    return rows.map((raw) {
      final m = raw as Map<String, dynamic>;
      final uuid = m['id'] as String;
      final id = _mapUuid(uuid);
      final rolled = m['rolled_back'] == true || m['rolled_back'] == 1;
      return ReleasePatch(
        id: id,
        number: (m['number'] as num?)?.toInt() ?? 0,
        channel: m['channel'] as String?,
        artifacts: const [],
        isRolledBack: rolled,
        notes: m['notes'] as String?,
      );
    }).toList();
  }

  /// Raw patch rows for a release version (includes package arches).
  Future<List<Map<String, dynamic>>> getPatchesByReleaseVersion({
    required String appId,
    required String releaseVersion,
    String? platform,
  }) async {
    final response = await _httpClient.get(
      Uri.parse('$_admin/patches').replace(
        queryParameters: {
          'app_id': appId,
          'release_version': releaseVersion,
        },
      ),
    );
    if (!response.isSuccess) _throw(response);
    final body = await _json(response);
    final rows = (body['patches'] as List? ?? const []);
    final out = <Map<String, dynamic>>[];
    for (final raw in rows) {
      if (raw is! Map) continue;
      final m = Map<String, dynamic>.from(raw);
      if (platform != null &&
          platform.isNotEmpty &&
          '${m['platform']}' != platform) {
        continue;
      }
      out.add(m);
    }
    return out;
  }

  Future<List<ReleaseArtifact>> getReleaseArtifacts({
    required String appId,
    required int releaseId,
    String? arch,
    ReleasePlatform? platform,
    ArtifactDownloadProgressCallback? onDownloadProgress,
  }) async {
    var cached = _releases[releaseId];
    if (cached == null) {
      // Fresh CLI process: hydrate release metadata from control_api first.
      await getReleases(appId: appId);
      cached = _releases[releaseId];
    }
    if (cached == null) return [];

    await _ensureReleaseArtifactsFromControlApi(
      appId: appId,
      releaseId: releaseId,
      cached: cached,
      arch: arch,
      platform: platform,
      onDownloadProgress: onDownloadProgress,
    );

    var artifacts = cached.artifacts.values.toList();
    if (platform != null) {
      artifacts = artifacts.where((a) => a.platform == platform).toList();
    }
    if (arch != null) {
      artifacts = artifacts.where((a) => a.arch == arch).toList();
    }
    return artifacts;
  }

  /// Ensures local `file://` release artifacts exist and match the cached hash.
  /// On miss / corruption / modification, re-downloads from
  /// `GET {base_url}/admin/v1/artifacts/<artifact_path>` (Bearer).
  Future<void> _ensureReleaseArtifactsFromControlApi({
    required String appId,
    required int releaseId,
    required _CachedRelease cached,
    String? arch,
    ReleasePlatform? platform,
    ArtifactDownloadProgressCallback? onDownloadProgress,
  }) async {
    final neededKeys = <String>{};
    if (platform != null && arch != null) {
      neededKeys.add('${platform.name}:$arch');
    } else if (cached.artifacts.isNotEmpty) {
      neededKeys.addAll(cached.artifacts.keys);
    }

    // Validate existing local files; drop stale entries so we re-fetch.
    for (final key in List<String>.from(cached.artifacts.keys)) {
      if (neededKeys.isNotEmpty && !neededKeys.contains(key)) continue;
      final artifact = cached.artifacts[key]!;
      if (!await _isLocalReleaseArtifactValid(artifact)) {
        cached.artifacts.remove(key);
      }
    }

    Future<bool> hydrateFromDisk({
      required String platformName,
      required String rowArch,
      required ReleasePlatform rowPlatform,
      String? expectedStoragePath,
    }) async {
      final key = '$platformName:$rowArch';
      if (cached.artifacts.containsKey(key)) return true;
      final disk = await _artifactCache.tryReadRelease(
        appId: appId,
        version: cached.version,
        platform: platformName,
        arch: rowArch,
      );
      if (disk == null) return false;

      final metaPath = disk.meta['storage_path'] as String?;
      if (expectedStoragePath != null &&
          expectedStoragePath.isNotEmpty &&
          metaPath != null &&
          metaPath.isNotEmpty &&
          metaPath != expectedStoragePath) {
        await _artifactCache.invalidate(disk.file);
        return false;
      }

      cached.artifacts[key] = _releaseArtifactFromDisk(
        releaseId: releaseId,
        arch: rowArch,
        platform: rowPlatform,
        cachedFile: disk,
      );
      return true;
    }

    if (platform != null && arch != null) {
      await hydrateFromDisk(
        platformName: platform.name,
        rowArch: arch,
        rowPlatform: platform,
      );
    }

    final missing = <String>{};
    if (platform != null && arch != null) {
      final key = '${platform.name}:$arch';
      if (!cached.artifacts.containsKey(key)) missing.add(key);
    } else if (cached.artifacts.isEmpty) {
      // Unknown which arches exist until we list releases from the server.
      missing.add('*');
    }

    if (missing.isEmpty) return;

    final response = await _httpClient.get(
      Uri.parse('$_admin/releases').replace(queryParameters: {'app_id': appId}),
    );
    if (!response.isSuccess) _throw(response);
    final body = await _json(response);
    final rows = (body['releases'] as List? ?? const []);

    for (final raw in rows) {
      final row = raw as Map<String, dynamic>;
      if ((row['version'] as String?) != cached.version) continue;
      final platformName = row['platform'] as String?;
      final rowArch = row['arch'] as String?;
      final storagePath = row['artifact_path'] as String?;
      if (platformName == null || rowArch == null) continue;
      if (storagePath == null || storagePath.isEmpty) continue;
      if (platform != null && platform.name != platformName) continue;
      if (arch != null && arch != rowArch) continue;

      final key = '$platformName:$rowArch';
      if (cached.artifacts.containsKey(key)) continue;

      ReleasePlatform rowPlatform;
      try {
        rowPlatform = ReleasePlatform.fromJson(platformName);
      } on FormatException {
        continue;
      }

      final fromDisk = await hydrateFromDisk(
        platformName: platformName,
        rowArch: rowArch,
        rowPlatform: rowPlatform,
        expectedStoragePath: storagePath,
      );
      if (fromDisk) continue;

      final bytes = await _downloadAdminArtifact(
        storagePath,
        label: rowArch,
        onDownloadProgress: onDownloadProgress,
      );
      final hash = sha256.convert(bytes).toString();
      final cachedFile = await _writeReleaseArtifactCache(
        appId: appId,
        version: cached.version,
        platform: rowPlatform,
        arch: rowArch,
        bytes: bytes,
        hash: hash,
        storagePath: storagePath,
      );

      cached.artifacts[key] = ReleaseArtifact(
        id: _nextId++,
        releaseId: releaseId,
        arch: rowArch,
        platform: rowPlatform,
        hash: hash,
        size: bytes.length,
        url: cachedFile.uri.toString(),
        canSideload: _isSideloadableArch(rowArch),
        podfileLockHash: null,
      );
    }
  }

  ReleaseArtifact _releaseArtifactFromDisk({
    required int releaseId,
    required String arch,
    required ReleasePlatform platform,
    required CachedArtifactFile cachedFile,
  }) {
    final hash =
        (cachedFile.meta['hash'] as String?) ??
        sha256.convert(cachedFile.bytes).toString();
    return ReleaseArtifact(
      id: _nextId++,
      releaseId: releaseId,
      arch: arch,
      platform: platform,
      hash: hash,
      size: cachedFile.bytes.length,
      url: cachedFile.file.uri.toString(),
      canSideload: _isSideloadableArch(arch),
      podfileLockHash: null,
    );
  }

  Future<List<int>> _downloadAdminArtifact(
    String storagePath, {
    required String label,
    ArtifactDownloadProgressCallback? onDownloadProgress,
  }) {
    return _downloadBytes(
      Uri.parse('$_admin/artifacts/$storagePath'),
      label: label,
      onDownloadProgress: onDownloadProgress,
    );
  }

  Future<List<int>> _downloadBytes(
    Uri uri, {
    required String label,
    ArtifactDownloadProgressCallback? onDownloadProgress,
  }) async {
    final request = http.Request('GET', uri);
    final streamed = await _httpClient.send(request);
    if (!streamed.isSuccess) {
      final body = await streamed.stream.bytesToString();
      throw _parseErrorResponse(streamed.statusCode, body);
    }

    final totalBytes = streamed.contentLength;
    final bytes = <int>[];
    var receivedBytes = 0;
    await for (final chunk in streamed.stream) {
      bytes.addAll(chunk);
      receivedBytes += chunk.length;
      onDownloadProgress?.call(
        ArtifactDownloadProgress(
          label: label,
          receivedBytes: receivedBytes,
          totalBytes: totalBytes,
        ),
      );
    }
    return bytes;
  }

  /// POSTs JSON, optionally streaming the body so [onUploadProgress] can report
  /// request-body bytes written.
  Future<http.Response> _postJson(
    Uri uri,
    Map<String, dynamic> body, {
    String? progressLabel,
    ArtifactUploadProgressCallback? onUploadProgress,
  }) async {
    final encoded = utf8.encode(json.encode(body));
    if (onUploadProgress == null || progressLabel == null) {
      return _httpClient.post(
        uri,
        headers: {'content-type': 'application/json'},
        body: encoded,
      );
    }

    final totalBytes = encoded.length;
    final request = http.StreamedRequest('POST', uri)
      ..headers['content-type'] = 'application/json'
      ..contentLength = totalBytes;

    final responseFuture = _httpClient.send(request);
    const chunkSize = 64 * 1024;
    var sentBytes = 0;
    onUploadProgress(
      ArtifactUploadProgress(
        label: progressLabel,
        sentBytes: 0,
        totalBytes: totalBytes,
      ),
    );
    for (var offset = 0; offset < encoded.length; offset += chunkSize) {
      final end = offset + chunkSize > encoded.length
          ? encoded.length
          : offset + chunkSize;
      request.sink.add(encoded.sublist(offset, end));
      sentBytes = end;
      onUploadProgress(
        ArtifactUploadProgress(
          label: progressLabel,
          sentBytes: sentBytes,
          totalBytes: totalBytes,
        ),
      );
    }
    await request.sink.close();
    final streamed = await responseFuture;
    return http.Response.fromStream(streamed);
  }

  Future<File> _writeReleaseArtifactCache({
    required String appId,
    required String version,
    required ReleasePlatform platform,
    required String arch,
    required List<int> bytes,
    required String hash,
    required String storagePath,
  }) async {
    final file = await _artifactCache.write(
      file: _artifactCache.releaseFile(
        appId: appId,
        version: version,
        platform: platform.name,
        arch: arch,
      ),
      bytes: bytes,
      meta: {
        'hash': hash,
        'size': bytes.length,
        'storage_path': storagePath,
      },
    );
    if (storagePath.isNotEmpty) {
      await _writeAdminArtifactCache(
        storagePath: storagePath,
        bytes: bytes,
        hash: hash,
      );
    }
    return file;
  }

  Future<File> _writeAdminArtifactCache({
    required String storagePath,
    required List<int> bytes,
    String? hash,
  }) {
    final resolvedHash = hash ?? sha256.convert(bytes).toString();
    return _artifactCache.write(
      file: _artifactCache.adminArtifactFile(storagePath),
      bytes: bytes,
      meta: {
        'hash': resolvedHash,
        'size': bytes.length,
        'storage_path': storagePath,
      },
    );
  }

  Future<bool> _isLocalReleaseArtifactValid(ReleaseArtifact artifact) async {
    final uri = Uri.tryParse(artifact.url);
    if (uri == null || uri.scheme != 'file') return false;
    final file = File(uri.toFilePath());
    if (!file.existsSync()) return false;
    final bytes = await file.readAsBytes();
    if (artifact.size > 0 && bytes.length != artifact.size) return false;
    if (artifact.hash.isNotEmpty) {
      final digest = sha256.convert(bytes).toString();
      if (digest != artifact.hash) return false;
    }
    return true;
  }

  Future<void> promotePatch({
    required String appId,
    required int patchId,
    required int channelId,
  }) async {
    final channel = _channelNames[channelId] ?? 'stable';
    final pending = _pendingPatches[patchId];
    final uuids = [
      if (pending != null) ...pending.remotePatchIds,
      if (_uuidOf(patchId) != null) _uuidOf(patchId)!,
    ].toSet();

    if (uuids.isEmpty) {
      throw CodePushNotFoundException(
        message: 'No remote patch for id $patchId',
      );
    }

    for (final uuid in uuids) {
      final response = await _httpClient.post(
        Uri.parse('$_admin/patches/$uuid/promote'),
        headers: {'content-type': 'application/json'},
        body: json.encode({'channel': channel}),
      );
      if (!response.isSuccess) _throw(response);
    }

    // Update local patch number for success message.
    final p = _pendingPatches[patchId];
    if (p != null && p.number != null) {
      // Patch object already returned earlier; publishPatch uses patch.number
      // from createPatch (0). Fix by storing on pending for callers that
      // re-read — publishPatch prints patch.number from createPatch return.
    }
  }

  Future<bool> rollbackPatch({
    required String appId,
    required int releaseId,
    required int patchId,
  }) async {
    final uuid = _uuidOf(patchId);
    if (uuid == null) {
      throw CodePushNotFoundException(message: 'Unknown patch id $patchId');
    }
    final response = await _httpClient.post(
      Uri.parse('$_admin/patches/$uuid/rollback'),
    );
    if (response.statusCode == HttpStatus.notModified) return false;
    if (!response.isSuccess) _throw(response);
    return true;
  }

  Future<bool> rollforwardPatch({
    required String appId,
    required int releaseId,
    required int patchId,
  }) async {
    // control_api: promote again clears rollback.
    await promotePatch(appId: appId, patchId: patchId, channelId: 1);
    return true;
  }

  Future<List<OrganizationMembership>> getOrganizationMemberships() async {
    final now = DateTime.now().toUtc();
    return [
      OrganizationMembership(
        organization: Organization(
          id: 1,
          name: 'FlutterPatch',
          organizationType: OrganizationType.personal,
          createdAt: now,
          updatedAt: now,
        ),
        role: Role.owner,
      ),
    ];
  }

  Future<Uri> getGCPUploadSpeedTestUrl() async {
    throw const CodePushException(
      message: 'GCP diagnostics are not available on FlutterPatch control_api',
    );
  }

  Future<Uri> getGCPDownloadSpeedTestUrl() async {
    throw const CodePushException(
      message: 'GCP diagnostics are not available on FlutterPatch control_api',
    );
  }

  /// Patch number assigned by control_api after artifact upload(s).
  int? patchNumberFor(int patchId) => _pendingPatches[patchId]?.number;

  void close() => _httpClient.close();

  /// control_api does not store `can_sideload`; infer from known installable
  /// artifact arch names used by Shorebird-compatible release uploads.
  bool _isSideloadableArch(String arch) => const {
    'aab',
    'runner',
    'app',
    'bundle',
    'win_archive',
  }.contains(arch);

  CodePushException _parseErrorResponse(int statusCode, String response) {
    final exceptionBuilder = switch (statusCode) {
      HttpStatus.conflict => CodePushConflictException.new,
      HttpStatus.notFound => CodePushNotFoundException.new,
      HttpStatus.upgradeRequired => CodePushUpgradeRequiredException.new,
      HttpStatus.forbidden => CodePushForbiddenException.new,
      _ => CodePushException.new,
    };

    try {
      final body = json.decode(response) as Map<String, dynamic>;
      final message =
          (body['message'] as String?) ??
          (body['error'] as String?) ??
          (body['detail'] as String?) ??
          unknownErrorMessage;
      return exceptionBuilder(message: message, details: response);
    } on Exception {
      return exceptionBuilder(message: unknownErrorMessage, details: response);
    }
  }
}

extension on http.BaseResponse {
  bool get isSuccess => statusCode >= 200 && statusCode < 300;
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    if (iterator.moveNext()) return iterator.current;
    return null;
  }
}
