// flutterpatch: ownership=OURS — from meta_ota
import 'dart:io';

import 'package:path/path.dart' as p;

/// Preferred ignore file name under the Flutter project root (or a parent dir).
const String flutterPatchIgnoreFileName = '.flutterpatchignore';

/// Legacy meta_ota ignore file (still loaded for compatibility).
const String metaOtaIgnoreFileName = '.meta_otaignore';

/// Supported platform section headers in ignore files: `[android]` / `[ios]`.
const Set<String> ignorePlatformSections = {'android', 'ios'};

/// Project-level ignore rules for OTA snapshot / resource scanning.
///
/// Syntax is a gitignore subset:
/// - blank lines and `#` comments are ignored
/// - `*` matches within one path segment; `**` matches across segments
/// - trailing `/` matches a directory prefix only
/// - leading `/` anchors to the path root
/// - a name without `/` matches that file or directory anywhere
/// - `!pattern` negates a previous ignore (re-includes)
/// - `[android]` / `[ios]` section headers: rules below apply only when that
///   platform is being checked (unscoped rules always apply)
class FlutterPatchIgnore {
  FlutterPatchIgnore._({
    required this.projectDir,
    required this.filePath,
    required this.platform,
    required List<_IgnoreRule> rules,
  }) : _rules = rules;

  /// Directory used as the search start (usually Flutter app dir).
  final String projectDir;

  /// Absolute path of the loaded ignore file, or null if none existed.
  final String? filePath;

  /// Platform filter used when loading (`android` / `ios`), or null for all.
  final String? platform;

  final List<_IgnoreRule> _rules;

  bool get isEmpty => _rules.isEmpty;

  int get ruleCount => _rules.length;

  /// Load `.flutterpatchignore` or legacy `.meta_otaignore`, walking up parents.
  ///
  /// When [platform] is `android` or `ios`, only unscoped rules and that
  /// platform's section are kept. When null, all sections are included.
  factory FlutterPatchIgnore.load(String projectDir, {String? platform}) {
    final start = p.normalize(p.absolute(projectDir));
    final found = _findIgnoreFile(start);
    if (found == null) {
      return FlutterPatchIgnore._(
        projectDir: start,
        filePath: null,
        platform: platform,
        rules: const [],
      );
    }
    return FlutterPatchIgnore.parse(
      File(found).readAsStringSync(),
      projectDir: start,
      filePath: found,
      platform: platform,
    );
  }

  static String? _findIgnoreFile(String startDir) {
    var dir = Directory(startDir);
    for (var i = 0; i < 20; i++) {
      for (final name in [flutterPatchIgnoreFileName, metaOtaIgnoreFileName]) {
        final candidate = File(p.join(dir.path, name));
        if (candidate.existsSync()) {
          return p.normalize(candidate.absolute.path);
        }
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
  }

  /// Parse ignore file contents.
  factory FlutterPatchIgnore.parse(
    String contents, {
    String projectDir = '',
    String? filePath,
    String? platform,
  }) {
    final normalizedPlatform = _normalizePlatform(platform);
    final rules = <_IgnoreRule>[];
    String? currentSection;

    for (final rawLine in contents.split(RegExp(r'\r?\n'))) {
      var line = rawLine.trimRight();
      if (line.isEmpty) continue;
      if (line.trimLeft().startsWith('#')) continue;

      final section = _parseSectionHeader(line.trim());
      if (section != null) {
        currentSection = section;
        continue;
      }

      // Skip rules from a platform section that does not match [platform].
      if (currentSection != null &&
          normalizedPlatform != null &&
          currentSection != normalizedPlatform) {
        continue;
      }

      var negate = false;
      if (line.startsWith('!')) {
        negate = true;
        line = line.substring(1);
      }
      line = line.trim();
      if (line.isEmpty) continue;

      rules.add(
        _IgnoreRule(
          pattern: line.replaceAll('\\', '/'),
          negate: negate,
        ),
      );
    }
    return FlutterPatchIgnore._(
      projectDir: projectDir,
      filePath: filePath,
      platform: normalizedPlatform,
      rules: rules,
    );
  }

  factory FlutterPatchIgnore.empty({
    String projectDir = '',
    String? platform,
  }) =>
      FlutterPatchIgnore._(
        projectDir: projectDir,
        filePath: null,
        platform: _normalizePlatform(platform),
        rules: const [],
      );

  static String? _normalizePlatform(String? platform) {
    if (platform == null || platform.isEmpty) return null;
    final p = platform.trim().toLowerCase();
    if (!ignorePlatformSections.contains(p)) {
      throw ArgumentError.value(
        platform,
        'platform',
        'must be one of: ${ignorePlatformSections.join(", ")}',
      );
    }
    return p;
  }

  /// `[android]` / `[ios]` (case-insensitive). Returns null if not a header.
  static String? _parseSectionHeader(String line) {
    if (!line.startsWith('[') || !line.endsWith(']')) return null;
    final name = line.substring(1, line.length - 1).trim().toLowerCase();
    if (ignorePlatformSections.contains(name)) return name;
    return null;
  }

  /// Whether [path] (posix, as stored in snapshot/resources) should be skipped.
  bool isIgnored(String path) {
    if (_rules.isEmpty) return false;
    final normalized = path.replaceAll('\\', '/');
    if (normalized.isEmpty) return false;

    var ignored = false;
    for (final rule in _rules) {
      if (rule.matches(normalized)) {
        ignored = !rule.negate;
      }
    }
    return ignored;
  }

  /// Whether a snapshot path should be skipped under local ignore rules.
  ///
  /// Checks the full stored path (e.g. `package:foo/lib/x.dart`) and, for
  /// dependency entries, the package-relative path (`lib/x.dart`) as well.
  bool isIgnoredSnapshotPath(String path) {
    final normalized = path.replaceAll('\\', '/');
    if (isIgnored(normalized)) return true;
    if (normalized.startsWith('package:')) {
      final slash = normalized.indexOf('/', 'package:'.length);
      if (slash != -1 && isIgnored(normalized.substring(slash + 1))) {
        return true;
      }
    }
    return false;
  }

  /// Whether a scanned asset (`package` + relative [path]) should be skipped.
  bool isIgnoredAsset({required String package, required String path}) {
    final rel = path.replaceAll('\\', '/');
    if (isIgnored(rel)) return true;
    if (package.isNotEmpty && isIgnored('package:$package/$rel')) {
      return true;
    }
    return false;
  }
}

/// @nodoc — alias for callers migrating from meta_ota.
typedef MetaOtaIgnore = FlutterPatchIgnore;

class _IgnoreRule {
  _IgnoreRule({required this.pattern, required this.negate})
    : _regex = _compile(pattern);

  final String pattern;
  final bool negate;
  final RegExp _regex;

  bool matches(String path) => _regex.hasMatch(path);

  static RegExp _compile(String rawPattern) {
    var pattern = rawPattern;
    if (pattern.startsWith('/')) pattern = pattern.substring(1);
    final dirOnly = pattern.endsWith('/');
    if (dirOnly) pattern = pattern.substring(0, pattern.length - 1);

    final anchored = rawPattern.startsWith('/');
    final hasSlash = pattern.contains('/');
    final basenameRule = !anchored && !hasSlash;

    final buf = StringBuffer();
    if (anchored || hasSlash) {
      buf.write('^');
    } else {
      buf.write('(^|/)');
    }

    buf.write(_globToRegex(pattern));

    if (dirOnly || basenameRule) {
      buf.write(r'(?:/.*)?$');
    } else {
      buf.write(r'$');
    }

    return RegExp(buf.toString());
  }

  static String _globToRegex(String glob) {
    final buf = StringBuffer();
    for (var i = 0; i < glob.length; i++) {
      final c = glob[i];
      if (c == '*' && i + 1 < glob.length && glob[i + 1] == '*') {
        i++;
        if (i + 1 < glob.length && glob[i + 1] == '/') {
          i++;
          buf.write('(?:.*/)?');
        } else {
          buf.write('.*');
        }
        continue;
      }
      switch (c) {
        case '*':
          buf.write('[^/]*');
        case '?':
          buf.write('[^/]');
        case '.':
        case '+':
        case '(':
        case ')':
        case '[':
        case ']':
        case '{':
        case '}':
        case '|':
        case '^':
        case r'$':
        case '\\':
          buf.write('\\$c');
        default:
          buf.write(c);
      }
    }
    return buf.toString();
  }
}
