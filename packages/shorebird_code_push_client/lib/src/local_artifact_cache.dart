// flutterpatch: ownership=OURS
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// A file plus the `.meta.json` sidecar stored next to it.
class CachedArtifactFile {
  /// Creates a cache hit wrapping [file], [bytes], and decoded [meta].
  CachedArtifactFile({
    required this.file,
    required this.bytes,
    required this.meta,
  });

  /// Path of the cached blob.
  final File file;

  /// File contents.
  final List<int> bytes;

  /// Sidecar metadata (`hash`, `size`, and type-specific fields).
  final Map<String, dynamic> meta;
}

/// Durable on-disk cache for control_api artifacts.
///
/// Layout under [root]:
/// - `releases/<appId>/<version>/<platform>_<arch>`
/// - `snapshots/<id>`
/// - `resources/<id>`
/// - `patches/<appId>/<version>/<platform>_<arch>_<number>`
///
/// Each file has a sibling `<name>.meta.json` with at least `hash` and `size`.
class LocalArtifactCache {
  /// Creates a cache rooted at [root], or system temp if omitted.
  LocalArtifactCache({Directory? root})
    : root =
          root ??
          Directory(
            p.join(Directory.systemTemp.path, 'flutterpatch_artifact_cache'),
          );

  /// Cache root. CLI injects `{shorebirdRoot}/bin/cache/flutterpatch`.
  final Directory root;

  /// Pre-migration release cache location (system temp).
  static Directory get legacyReleaseCacheRoot {
    return Directory(
      p.join(Directory.systemTemp.path, 'flutterpatch_release_cache'),
    );
  }

  /// Release binary path for [appId] / [version] / [platform] / [arch].
  File releaseFile({
    required String appId,
    required String version,
    required String platform,
    required String arch,
  }) {
    return File(
      p.join(
        root.path,
        'releases',
        _safe(appId),
        _safe(version),
        '${_safe(platform)}_${_safe(arch)}',
      ),
    );
  }

  /// OTA snapshot JSON path keyed by control_api [id].
  File snapshotFile(String id) {
    return File(p.join(root.path, 'snapshots', _safe(id)));
  }

  /// Resource config JSON path keyed by control_api [id].
  File resourceFile(String id) {
    return File(p.join(root.path, 'resources', _safe(id)));
  }

  /// Patch binary path keyed by release + patch [number].
  File patchFile({
    required String appId,
    required String version,
    required String platform,
    required String arch,
    required int number,
  }) {
    return File(
      p.join(
        root.path,
        'patches',
        _safe(appId),
        _safe(version),
        '${_safe(platform)}_${_safe(arch)}_$number',
      ),
    );
  }

  /// Writes [bytes] and a `.meta.json` sidecar next to [file].
  Future<File> write({
    required File file,
    required List<int> bytes,
    required Map<String, Object?> meta,
  }) async {
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    await File('${file.path}.meta.json').writeAsString(
      json.encode(meta),
      flush: true,
    );
    return file;
  }

  /// Returns the cached file if it exists and matches meta `size` / `hash`.
  /// On corruption, deletes the entry and returns null.
  Future<CachedArtifactFile?> tryRead(File file) async {
    final metaFile = File('${file.path}.meta.json');
    if (!file.existsSync() || !metaFile.existsSync()) return null;

    Map<String, dynamic> meta;
    try {
      final decoded = json.decode(await metaFile.readAsString());
      if (decoded is! Map<dynamic, dynamic>) {
        await invalidate(file);
        return null;
      }
      meta = Map<String, dynamic>.from(decoded);
    } on Object {
      await invalidate(file);
      return null;
    }

    final expectedSize = (meta['size'] as num?)?.toInt();
    final actualSize = await file.length();
    if (expectedSize != null && expectedSize != actualSize) {
      await invalidate(file);
      return null;
    }

    final bytes = await file.readAsBytes();
    final expectedHash = meta['hash'] as String?;
    if (expectedHash != null && expectedHash.isNotEmpty) {
      if (sha256.convert(bytes).toString() != expectedHash) {
        await invalidate(file);
        return null;
      }
    }

    return CachedArtifactFile(file: file, bytes: bytes, meta: meta);
  }

  /// Reads a release artifact from the current cache, then the legacy temp
  /// path. A legacy hit is copied into [root] so later lookups stay durable.
  Future<CachedArtifactFile?> tryReadRelease({
    required String appId,
    required String version,
    required String platform,
    required String arch,
  }) async {
    final primary = releaseFile(
      appId: appId,
      version: version,
      platform: platform,
      arch: arch,
    );
    final hit = await tryRead(primary);
    if (hit != null) return hit;

    final legacy = File(
      p.join(
        legacyReleaseCacheRoot.path,
        appId,
        version,
        '${platform}_$arch',
      ),
    );
    if (p.equals(legacy.path, primary.path)) return null;

    final legacyHit = await tryRead(legacy);
    if (legacyHit == null) return null;

    await write(
      file: primary,
      bytes: legacyHit.bytes,
      meta: Map<String, Object?>.from(legacyHit.meta),
    );
    return tryRead(primary);
  }

  /// Deletes [file] and its `.meta.json` sidecar if they exist.
  Future<void> invalidate(File file) async {
    final metaFile = File('${file.path}.meta.json');
    if (file.existsSync()) {
      await file.delete();
    }
    if (metaFile.existsSync()) {
      await metaFile.delete();
    }
  }

  static String _safe(String value) {
    return value.replaceAll(RegExp(r'[\\/]+'), '_').replaceAll('..', '_');
  }
}
