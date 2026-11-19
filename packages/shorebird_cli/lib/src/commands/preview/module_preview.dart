// cspell:words xcworkspace xcodeproj iphoneos
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/config/config.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';

/// Resolves a path from shorebird.yaml preview config.
///
/// Relative paths are resolved against [configRoot] (the directory that
/// contains shorebird.yaml). Absolute paths are returned normalized.
String resolvePreviewPath({
  required String path,
  required Directory configRoot,
}) {
  final trimmed = path.trim();
  if (p.isAbsolute(trimmed)) {
    return p.normalize(trimmed);
  }
  return p.normalize(p.join(configRoot.path, trimmed));
}

/// Human-readable instructions when module preview config is missing.
String missingModulePreviewConfigMessage({
  required ReleasePlatform platform,
}) {
  return switch (platform) {
    ReleasePlatform.android => '''
Module preview needs an Android host project.

Set the top-level host path (preferred for modules):

android: ../your_android_app

Or, for full control:

preview:
  android:
    host_project: ../your_android_app
    artifact_dir: release
    application_id: com.example.host
    # optional:
    # assemble_task: :app:assembleRelease
    # build_number: "1.0"

Then re-run: flutterpatch preview --platform=android
''',
    ReleasePlatform.ios => '''
Module preview needs an iOS host project.

Set the top-level host path (preferred for modules):

ios: ../your_ios_app

Or, for full control:

preview:
  ios:
    host_project: ../your_ios_app
    frameworks_dir: ../your_ios_app/Flutter
    scheme: YourHostScheme
    # optional:
    # configuration: Release
    # workspace: YourHost.xcworkspace
    # xcodeproj: YourHost.xcodeproj

Then re-run: flutterpatch preview --platform=ios
''',
    _ => '''
Module preview is only supported for Android (aar) and iOS (ios-framework).
''',
  };
}

/// Reads `applicationId` (or `namespace`) from a native Android host project.
String? readAndroidHostApplicationId(Directory hostProject) {
  for (final rel in [
    'app/build.gradle.kts',
    'app/build.gradle',
    'build.gradle.kts',
    'build.gradle',
  ]) {
    final file = File(p.join(hostProject.path, rel));
    if (!file.existsSync()) continue;
    final text = file.readAsStringSync();
    final appId = RegExp(
      r'''applicationId\s*[= ]\s*["']([^"']+)["']''',
    ).firstMatch(text)?.group(1);
    if (appId != null && appId.isNotEmpty) return appId.trim();
    final ns = RegExp(
      r'''namespace\s*[= ]\s*["']([^"']+)["']''',
    ).firstMatch(text)?.group(1);
    if (ns != null && ns.isNotEmpty) return ns.trim();
  }
  return null;
}

/// Infers an Xcode scheme from the first `.xcodeproj` under [hostProject].
String? inferIosHostScheme(Directory hostProject) {
  if (!hostProject.existsSync()) return null;
  final projects = hostProject
      .listSync()
      .whereType<Directory>()
      .where((d) => d.path.endsWith('.xcodeproj'))
      .toList();
  if (projects.isEmpty) return null;
  return p.basenameWithoutExtension(projects.first.path);
}

/// Default frameworks directory for module preview (relative to config root).
String defaultIosFrameworksDir(String hostProject) {
  return p.posix.join(hostProject.replaceAll(r'\', '/'), 'Flutter');
}

/// Returns a validated [PreviewAndroidConfig], or logs an error and returns
/// `null` when required fields are missing.
///
/// Falls back to top-level `shorebird.yaml` → `android` for [hostProject]
/// when `preview.android.host_project` is omitted. Defaults `artifact_dir`
/// to `release` and reads `application_id` from the host Gradle files when
/// not set under `preview.android`.
PreviewAndroidConfig? requireAndroidPreviewConfig({
  required ShorebirdYaml? yaml,
  required Logger logger,
  Directory? configRoot,
}) {
  final explicit = yaml?.preview?.android;
  final hostProject = _nonEmpty(explicit?.hostProject) ??
      _nonEmpty(yaml?.android);
  if (hostProject == null) {
    logger.err(
      missingModulePreviewConfigMessage(platform: ReleasePlatform.android),
    );
    return null;
  }

  final artifactDir = _nonEmpty(explicit?.artifactDir) ?? 'release';

  var applicationId = _nonEmpty(explicit?.applicationId);
  if (applicationId == null && configRoot != null) {
    final hostDir = Directory(
      resolvePreviewPath(path: hostProject, configRoot: configRoot),
    );
    applicationId = readAndroidHostApplicationId(hostDir);
  }
  if (applicationId == null) {
    logger.err(
      'Could not resolve host application_id. '
      'Set preview.android.application_id in shorebird.yaml, or ensure the '
      'host project declares applicationId in app/build.gradle.',
    );
    return null;
  }

  return PreviewAndroidConfig(
    hostProject: hostProject,
    artifactDir: artifactDir,
    applicationId: applicationId,
    assembleTask: explicit?.assembleTask ?? ':app:assembleRelease',
    buildNumber: explicit?.buildNumber ?? '1.0',
  );
}

/// Returns a validated [PreviewIosConfig], or logs an error and returns
/// `null` when required fields are missing.
///
/// Falls back to top-level `shorebird.yaml` → `ios` for [hostProject] when
/// `preview.ios.host_project` is omitted. Defaults `frameworks_dir` to
/// `<host>/Flutter` and infers `scheme` from the host `.xcodeproj` name
/// when not set under `preview.ios`.
PreviewIosConfig? requireIosPreviewConfig({
  required ShorebirdYaml? yaml,
  required Logger logger,
  Directory? configRoot,
}) {
  final explicit = yaml?.preview?.ios;
  final hostProject = _nonEmpty(explicit?.hostProject) ??
      _nonEmpty(yaml?.ios);
  if (hostProject == null) {
    logger.err(
      missingModulePreviewConfigMessage(platform: ReleasePlatform.ios),
    );
    return null;
  }

  final frameworksDir = _nonEmpty(explicit?.frameworksDir) ??
      defaultIosFrameworksDir(hostProject);

  var scheme = _nonEmpty(explicit?.scheme);
  if (scheme == null && configRoot != null) {
    final hostDir = Directory(
      resolvePreviewPath(path: hostProject, configRoot: configRoot),
    );
    scheme = inferIosHostScheme(hostDir);
  }
  if (scheme == null) {
    logger.err(
      'Could not resolve preview.ios.scheme. '
      'Set preview.ios.scheme in shorebird.yaml, or ensure the host project '
      'contains an .xcodeproj.',
    );
    return null;
  }

  return PreviewIosConfig(
    hostProject: hostProject,
    frameworksDir: frameworksDir,
    scheme: scheme,
    configuration: explicit?.configuration ?? 'Release',
    workspace: explicit?.workspace,
    xcodeproj: explicit?.xcodeproj,
  );
}

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return trimmed;
}

/// Maven path for a Flutter module release AAR under [artifactDir].
String moduleAarArtifactPath({
  required String artifactDir,
  required String packageName,
  required String buildNumber,
}) {
  return p.joinAll([
    artifactDir,
    ...packageName.split('.'),
    'flutter_release',
    buildNumber,
    'flutter_release-$buildNumber.aar',
  ]);
}

/// Minimal POM so Gradle can resolve the replaced AAR from a local maven repo.
String moduleAarPomContents({
  required String packageName,
  required String buildNumber,
}) {
  return '''
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>$packageName</groupId>
  <artifactId>flutter_release</artifactId>
  <version>$buildNumber</version>
  <packaging>aar</packaging>
</project>
''';
}

/// Finds the newest host APK under [hostProject] build outputs.
File? findNewestHostApk(Directory hostProject) {
  final outputs = Directory(
    p.join(hostProject.path, 'app', 'build', 'outputs'),
  );
  if (!outputs.existsSync()) {
    // Some hosts put the app module at the repo root.
    final rootOutputs = Directory(p.join(hostProject.path, 'build', 'outputs'));
    if (!rootOutputs.existsSync()) return null;
    return _newestApkUnder(rootOutputs);
  }
  return _newestApkUnder(outputs);
}

File? _newestApkUnder(Directory root) {
  final apks = root
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.apk') && !f.path.contains('androidTest'))
      .toList();
  if (apks.isEmpty) return null;
  apks.sort(
    (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
  );
  return apks.first;
}

/// Resolves the Xcode workspace or project args for `xcodebuild`.
///
/// Returns either `['-workspace', path]` or `['-project', path]`.
List<String> resolveXcodeBuildTargetArgs({
  required Directory hostProject,
  required PreviewIosConfig config,
}) {
  String? resolveOptional(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    if (p.isAbsolute(trimmed)) return p.normalize(trimmed);
    return p.normalize(p.join(hostProject.path, trimmed));
  }

  final workspace = resolveOptional(config.workspace);
  if (workspace != null && Directory(workspace).existsSync()) {
    return ['-workspace', workspace];
  }

  final xcodeproj = resolveOptional(config.xcodeproj);
  if (xcodeproj != null && Directory(xcodeproj).existsSync()) {
    return ['-project', xcodeproj];
  }

  final workspaces = hostProject
      .listSync()
      .whereType<Directory>()
      .where((d) => d.path.endsWith('.xcworkspace'))
      .where((d) => !d.path.contains('.xcodeproj/'))
      .toList();
  if (workspaces.isNotEmpty) {
    return ['-workspace', workspaces.first.path];
  }

  final projects = hostProject
      .listSync()
      .whereType<Directory>()
      .where((d) => d.path.endsWith('.xcodeproj'))
      .toList();
  if (projects.isNotEmpty) {
    return ['-project', projects.first.path];
  }

  throw Exception(
    'Could not find an .xcworkspace or .xcodeproj under ${hostProject.path}. '
    'Set preview.ios.workspace or preview.ios.xcodeproj in shorebird.yaml.',
  );
}

/// Finds the built `.app` under [derivedData] for [configuration].
Directory? findBuiltIosApp({
  required Directory derivedData,
  required String configuration,
}) {
  final products = Directory(
    p.join(derivedData.path, 'Build', 'Products'),
  );
  if (!products.existsSync()) return null;

  final candidates = <Directory>[];
  for (final dir in products.listSync().whereType<Directory>()) {
    final name = p.basename(dir.path);
    if (!name.startsWith(configuration)) continue;
    if (!name.contains('iphoneos')) continue;
    candidates.addAll(
      dir.listSync().whereType<Directory>().where(
        (d) => d.path.endsWith('.app'),
      ),
    );
  }
  if (candidates.isEmpty) return null;
  candidates.sort(
    (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
  );
  return candidates.first;
}
