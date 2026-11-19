import 'dart:io';

/// FlutterPatch defaults for Flutter git + engine artifact CDN.
///
/// Override with env (full URL) to fall back to upstream Shorebird/GitHub:
/// - [flutterGitUrlEnvKey] → e.g. [officialFlutterGitUrl]
/// - [engineCdnEnvKey] → e.g. [officialEngineCdnBaseUrl]
class FlutterpatchMirrors {
  FlutterpatchMirrors._();

  /// Env: Flutter fork clone URL.
  static const flutterGitUrlEnvKey = 'FLUTTERPATCH_FLUTTER_GIT_URL';

  /// Env: `FLUTTER_STORAGE_BASE_URL` value when spawning Flutter.
  static const engineCdnEnvKey = 'FLUTTERPATCH_ENGINE_CDN';

  /// Upstream Shorebird Flutter fork (fallback).
  static const officialFlutterGitUrl =
      'https://github.com/shorebirdtech/flutter.git';

  /// FlutterPatch Gitee mirror (default).
  static const defaultFlutterGitUrl =
      'https://gitee.com/joser_zhang_admin/flutterpatch_flutter.git';

  /// Upstream Shorebird engine CDN (fallback).
  static const officialEngineCdnBaseUrl = 'https://download.shorebird.dev';

  /// FlutterPatch engine proxy (default).
  static const defaultEngineCdnBaseUrl = 'https://engine.flutterpatch.cn';

  /// Resolved Flutter git URL (env override or [defaultFlutterGitUrl]).
  static String get flutterGitUrl {
    final fromEnv = Platform.environment[flutterGitUrlEnvKey]?.trim();
    if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
    return defaultFlutterGitUrl;
  }

  /// Resolved engine CDN base (no trailing slash).
  static String get engineCdnBaseUrl {
    final fromEnv = Platform.environment[engineCdnEnvKey]?.trim();
    if (fromEnv != null && fromEnv.isNotEmpty) {
      return _trimSlash(fromEnv);
    }
    return defaultEngineCdnBaseUrl;
  }

  /// Env map applied when the CLI runs `flutter`.
  static Map<String, String> get flutterStorageEnvironment => {
    'FLUTTER_STORAGE_BASE_URL': engineCdnBaseUrl,
  };

  static String _trimSlash(String value) {
    if (value.endsWith('/')) {
      return value.substring(0, value.length - 1);
    }
    return value;
  }
}
