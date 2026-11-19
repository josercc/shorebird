// flutterpatch: ownership=UPSTREAM — preview restored for control_api
// cspell:words devicectl endtemplate bryanoltman sideloadable previewable apks
// cspell:words bundletool
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:collection/collection.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/artifact_manager.dart';
import 'package:shorebird_cli/src/cache.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/commands/preview/module_preview.dart';
import 'package:shorebird_cli/src/common_arguments.dart';
import 'package:shorebird_cli/src/config/config.dart';
import 'package:shorebird_cli/src/deployment_track.dart';
import 'package:shorebird_cli/src/executables/devicectl/apple_device.dart';
import 'package:shorebird_cli/src/executables/executables.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_cli/src/platform/platform.dart';
import 'package:shorebird_cli/src/release_chooser.dart';
import 'package:shorebird_cli/src/shorebird_command.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_process.dart';
import 'package:shorebird_cli/src/shorebird_validator.dart';
import 'package:shorebird_cli/src/third_party/flutter_tools/lib/flutter_tools.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

/// {@template preview_command}
/// `flutterpatch preview` command.
/// {@endtemplate}
class PreviewCommand extends ShorebirdCommand {
  /// {@macro preview_command}
  PreviewCommand() {
    argParser
      ..addOption(
        'device-id',
        abbr: 'd',
        help: 'The ID of the device or simulator to preview the release on.',
      )
      ..addOption(
        'app-id',
        help: 'The ID of the app to preview the release for.',
      )
      ..addOption(
        CommonArguments.releaseVersionArg.name,
        help: CommonArguments.releaseVersionArg.description,
      )
      ..addOption(
        'platform',
        allowed: ReleasePlatform.values.map((e) => e.name),
        allowedHelp: {
          for (final p in ReleasePlatform.values) p.name: p.displayName,
        },
        help: 'The platform of the release.',
      )
      ..addOption(
        'ks',
        help: '''
Specifies the path to the deployment keystore used to sign the APKs.
If you don't include this flag, bundletool attempts to sign your APKs with a debug signing key.
This is only applicable when previewing Android releases.''',
      )
      ..addOption(
        'ks-pass',
        help: '''
Specifies your keystore password.
If you specify a password in plain text, qualify it with pass:.
If you pass the path to a file that contains the password, qualify it with file:.
If you specify a keystore using the --ks flag you must also specify a password.
This is only applicable when previewing Android releases.''',
      )
      ..addOption(
        'ks-key-pass',
        help: '''
Specifies the password for the signing key. If you specify a password in plain text, qualify it with pass:.
If you pass the path to a file that contains the password, qualify it with file:.
If this password is identical to the one for the keystore itself, you can omit this flag.
This is only applicable when previewing Android releases.''',
      )
      ..addOption(
        'ks-key-alias',
        help: '''
Specifies the alias of the signing key you want to use.
This is only applicable when previewing Android releases.''',
      )
      ..addFlag(
        'staging',
        negatable: false,
        help:
            '''[DEPRECATED] Preview the release on the staging environment. Use --track=staging instead.''',
        hide: true,
      )
      ..addOption(
        'track',
        help: 'The track to preview.',
        defaultsTo: DeploymentTrack.stable.channel,
      );
  }

  /// Returns the platforms that can be previewed on the current OS.
  static List<ReleasePlatform> get supportedReleasePlatforms {
    if (platform.isMacOS) {
      return ReleasePlatform.values;
    } else {
      return ReleasePlatform.values
          .where((p) => p != ReleasePlatform.ios)
          .toList();
    }
  }

  @override
  String get name => 'preview';

  @override
  String get description => 'Preview a specific release on a device.';

  /// The deployment track to publish the patch to.
  DeploymentTrack get track => DeploymentTrack(results['track'] as String);

  @override
  Future<int> run() async {
    // TODO(bryanoltman): check preview target and run either
    // doctor.iosValidators or doctor.androidValidators as appropriate.
    try {
      await shorebirdValidator.validatePreconditions(
        checkUserIsAuthenticated: true,
      );
    } on PreconditionFailedException catch (error) {
      return error.exitCode.code;
    }

    if (results.wasParsed('staging')) {
      logger.err(
        '''The --staging flag is deprecated and will be removed in a future release. Use --track=staging instead.''',
      );
      return ExitCode.usage.code;
    }

    final shorebirdYaml = shorebirdEnv.getShorebirdYaml();
    final String? appId;

    final flavors = shorebirdYaml?.flavors;

    if (results.wasParsed('app-id')) {
      appId = results['app-id'] as String;
    } else if (shorebirdYaml != null && flavors == null) {
      appId = shorebirdYaml.appId;
    } else if (shorebirdYaml != null && flavors != null) {
      final flavorOptions = flavors.keys.toList();
      final chosenFlavor = logger.chooseOne<String>(
        'Which app flavor?',
        choices: flavorOptions,
      );
      appId = flavors[chosenFlavor];
    } else {
      appId = await promptForApp();
    }

    if (appId == null) {
      logger.info('No apps found');
      return ExitCode.success.code;
    }

    // Flutter modules upload aar / xcframework artifacts with canSideload
    // false, so they never appear in sideloadable releases. Use all releases
    // for module preview; keep the sideloadable filter for standalone apps.
    final isModule = shorebirdEnv.isFlutterModule;
    final (allReleases, sideloadableReleases) = await (
      codePushClientWrapper.getReleases(appId: appId),
      isModule
          ? Future<List<Release>>.value(const <Release>[])
          : codePushClientWrapper.getReleases(
              appId: appId,
              sideloadableOnly: true,
            ),
    ).wait;

    final maybePlatform = results['platform'] != null
        ? ReleasePlatform.values.byName(results['platform'] as String)
        : null;

    final candidateReleases = isModule ? allReleases : sideloadableReleases;
    final platformReleases = candidateReleases
        .where(
          (r) =>
              maybePlatform == null ||
              r.activePlatforms.contains(maybePlatform),
        )
        .toList();

    if (platformReleases.isEmpty) {
      if (maybePlatform != null) {
        logger.err(
          isModule
              ? '''No ${maybePlatform.displayName} releases found for this module'''
              : '''No previewable ${maybePlatform.displayName} releases found''',
        );
      } else {
        logger.err(
          isModule
              ? 'No releases found for this module'
              : 'No previewable releases found for this app',
        );
      }
      return ExitCode.usage.code;
    }

    final releaseVersion =
        results['release-version'] as String? ??
        await promptForReleaseVersion(platformReleases);

    final release = platformReleases.firstWhereOrNull(
      (r) => r.version == releaseVersion,
    );

    if (release == null) {
      logger.err(
        isModule
            ? 'No releases found for version $releaseVersion'
            : 'No previewable releases found for version $releaseVersion',
      );
      return ExitCode.usage.code;
    }

    final availablePlatforms = release.activePlatforms
        .where((p) => supportedReleasePlatforms.contains(p))
        .toList();

    if (availablePlatforms.isEmpty) {
      final activePlatformsString = release.activePlatforms
          .map((p) => p.displayName)
          .join(', ');
      logger.err(
        '''This release can only be previewed on platforms that support $activePlatformsString''',
      );
      return ExitCode.usage.code;
    }

    if (!isModule) {
      final releaseWithAllPlatforms = allReleases.firstWhere(
        (r) => r.id == release.id,
      );
      assertPreviewableReleases(
        releaseWithAllPlatforms: releaseWithAllPlatforms,
        release: release,
        targetPlatform: maybePlatform,
      );
    }

    final ReleasePlatform releasePlatform;
    if (maybePlatform != null) {
      final matchedPlatform = release.activePlatforms.firstWhere(
        (p) => p == maybePlatform,
      );

      releasePlatform = matchedPlatform;
    } else if (availablePlatforms.length == 1) {
      releasePlatform = availablePlatforms.first;
    } else {
      releasePlatform = await promptForPlatform(availablePlatforms);
    }

    var deviceId = results['device-id'] as String?;
    if (releasePlatform == ReleasePlatform.android) {
      deviceId = await promptForAndroidDeviceId(deviceId: deviceId);
      if (deviceId == null) {
        return ExitCode.software.code;
      }
    } else if (releasePlatform == ReleasePlatform.ios) {
      deviceId = await promptForIosDeviceId(deviceId: deviceId);
    }

    if (isModule) {
      return switch (releasePlatform) {
        ReleasePlatform.android => installAndLaunchAndroidModule(
          appId: appId,
          release: release,
          deviceId: deviceId,
          track: track,
          shorebirdYaml: shorebirdYaml,
        ),
        ReleasePlatform.ios => installAndLaunchIosModule(
          appId: appId,
          release: release,
          deviceId: deviceId,
          track: track,
          shorebirdYaml: shorebirdYaml,
        ),
        _ => () {
          logger.err(
            '''Module preview only supports Android (aar) and iOS (ios-framework).''',
          );
          return ExitCode.usage.code;
        }(),
      };
    }

    return switch (releasePlatform) {
      ReleasePlatform.android => installAndLaunchAndroid(
        appId: appId,
        release: release,
        deviceId: deviceId,
        track: track,
      ),
      ReleasePlatform.ios => installAndLaunchIos(
        appId: appId,
        release: release,
        deviceId: deviceId,
        track: track,
      ),
      ReleasePlatform.linux => installAndLaunchLinux(
        appId: appId,
        release: release,
        track: track,
      ),
      ReleasePlatform.macos => installAndLaunchMacos(
        appId: appId,
        release: release,
        track: track,
      ),
      ReleasePlatform.windows => installAndLaunchWindows(
        appId: appId,
        release: release,
        track: track,
      ),
    };
  }

  /// Prompts the user to choose an app to preview.
  Future<String?> promptForApp() async {
    final apps = await codePushClientWrapper.getApps();
    if (apps.isEmpty) return null;
    final app = logger.chooseOne(
      'Which app would you like to preview?',
      choices: apps,
      display: (app) => app.displayName,
      hint:
          'Pass --app-id=<app-id> to preview a specific app without '
          'prompting.',
    );
    return app.appId;
  }

  /// Prompts the user to choose a release version to preview.
  Future<String> promptForReleaseVersion(List<Release> releases) async {
    final release = chooseRelease(
      releases: releases,
      action: 'preview',
    );
    return release.version;
  }

  /// Prompts the user to choose a platform to preview.
  Future<ReleasePlatform> promptForPlatform(
    List<ReleasePlatform> platforms,
  ) async {
    final platformNames = platforms.map((p) => p.displayName).toList();
    final platform = logger.chooseOne(
      'Which platform would you like to preview?',
      choices: platformNames,
      hint:
          'Pass --platform=<android|ios|...> to preview a specific platform '
          'without prompting.',
    );
    return ReleasePlatform.values.firstWhere((p) => p.displayName == platform);
  }

  /// Resolves an Android device id, prompting when multiple devices are
  /// connected and `--device-id` was not provided.
  ///
  /// Returns `null` when no usable device is available.
  Future<String?> promptForAndroidDeviceId({String? deviceId}) async {
    late final List<AndroidDevice> devices;
    try {
      devices = await adb.listDevices();
    } on Exception catch (error) {
      logger.err('$error');
      return null;
    }

    if (deviceId != null) {
      final matched = devices.firstWhereOrNull((d) => d.id == deviceId);
      if (matched == null && devices.isNotEmpty) {
        logger.warn(
          'Device "$deviceId" was not found in the connected device list. '
          'Continuing with the provided id.',
        );
      }
      return deviceId;
    }

    if (devices.isEmpty) {
      logger.err(
        'No Android devices found. Connect a device or start an emulator.',
      );
      return null;
    }

    if (devices.length == 1) {
      final device = devices.single;
      logger.info('Using device ${device.displayName}');
      return device.id;
    }

    final chosen = logger.chooseOne<AndroidDevice>(
      'Which device would you like to preview on?',
      choices: devices,
      display: (device) => device.displayName,
      hint: 'Pass --device-id=<id> to preview on a specific device '
          'without prompting.',
    );
    return chosen.id;
  }

  /// Resolves an iOS device id from currently available CoreDevices.
  ///
  /// When no iOS 17+ devices are visible to `devicectl` and `--device-id` was
  /// not provided, returns `null` so callers can fall back to `ios-deploy`.
  Future<String?> promptForIosDeviceId({String? deviceId}) async {
    late final List<AppleDevice> devices;
    try {
      devices = await devicectl.listAvailableIosDevices();
    } on Exception catch (error, stackTrace) {
      logger.detail('Failed to list iOS devices: $error $stackTrace');
      return deviceId;
    }

    if (deviceId != null) {
      final matched = devices.firstWhereOrNull((d) => d.udid == deviceId);
      if (matched == null && devices.isNotEmpty) {
        logger.warn(
          'Device "$deviceId" was not found in the connected device list. '
          'Continuing with the provided id.',
        );
      }
      return deviceId;
    }

    if (devices.isEmpty) {
      return null;
    }

    if (devices.length == 1) {
      final device = devices.single;
      logger.info('Using device ${device.name} (${device.udid})');
      return device.udid;
    }

    final chosen = logger.chooseOne<AppleDevice>(
      'Which device would you like to preview on?',
      choices: devices,
      display: (device) => '${device.name} (${device.udid})',
      hint: 'Pass --device-id=<udid> to preview on a specific device '
          'without prompting.',
    );
    return chosen.udid;
  }

  /// Downloads an `aar`, replaces it in the host Android project configured
  /// under `shorebird.yaml` → `preview.android` (or top-level `android`),
  /// builds the host, and installs it on a device.
  Future<int> installAndLaunchAndroidModule({
    required String appId,
    required Release release,
    required DeploymentTrack track,
    required ShorebirdYaml? shorebirdYaml,
    String? deviceId,
  }) async {
    final configRoot =
        shorebirdEnv.getShorebirdProjectRoot() ?? Directory.current;
    final previewConfig = requireAndroidPreviewConfig(
      yaml: shorebirdYaml,
      logger: logger,
      configRoot: configRoot,
    );
    if (previewConfig == null) {
      return ExitCode.usage.code;
    }

    final packageName = shorebirdEnv.androidPackageName;
    if (packageName == null) {
      logger.err('Could not find androidPackage in pubspec.yaml.');
      return ExitCode.config.code;
    }
    final hostProject = Directory(
      resolvePreviewPath(
        path: previewConfig.hostProject,
        configRoot: configRoot,
      ),
    );
    final artifactDir = Directory(
      resolvePreviewPath(
        path: previewConfig.artifactDir,
        configRoot: configRoot,
      ),
    );

    if (!hostProject.existsSync()) {
      logger.err('Host project not found: ${hostProject.path}');
      return ExitCode.config.code;
    }

    late final ReleaseArtifact releaseAarArtifact;
    try {
      releaseAarArtifact = await codePushClientWrapper.getReleaseArtifact(
        appId: appId,
        releaseId: release.id,
        arch: 'aar',
        platform: ReleasePlatform.android,
      );
    } on Exception catch (e, s) {
      logger
        ..err('Error getting release artifact: $e')
        ..detail('Stack trace: $s');
      return ExitCode.software.code;
    }

    late final File cachedAar;
    try {
      cachedAar = File(
        getArtifactPath(
          appId: appId,
          release: release,
          artifact: releaseAarArtifact,
          platform: ReleasePlatform.android,
          fileExtension: 'aar',
        ),
      );
      if (!cachedAar.existsSync()) {
        cachedAar.createSync(recursive: true);
        await artifactManager.downloadWithProgressUpdates(
          Uri.parse(releaseAarArtifact.url),
          message: 'Downloading aar',
          outputPath: cachedAar.path,
        );
      }
    } on Exception catch (error) {
      logger.err('$error');
      return ExitCode.software.code;
    }

    final channelProgress = logger.progress('Using $track track');
    try {
      await setChannelOnAar(aarFile: cachedAar, channel: track.channel);
      channelProgress.complete();
    } on Exception catch (error) {
      channelProgress.fail('$error');
      return ExitCode.software.code;
    }

    final targetAarPath = moduleAarArtifactPath(
      artifactDir: artifactDir.path,
      packageName: packageName,
      buildNumber: previewConfig.buildNumber,
    );
    final replaceProgress = logger.progress('Replacing host aar');
    try {
      final targetAar = File(targetAarPath)..createSync(recursive: true);
      cachedAar.copySync(targetAar.path);
      final pomFile = File(
        p.join(
          p.dirname(targetAarPath),
          'flutter_release-${previewConfig.buildNumber}.pom',
        ),
      );
      if (!pomFile.existsSync()) {
        pomFile.writeAsStringSync(
          moduleAarPomContents(
            packageName: packageName,
            buildNumber: previewConfig.buildNumber,
          ),
        );
      }
      replaceProgress.complete('Replaced ${cyan.wrap(targetAar.path)}');
    } on Exception catch (error) {
      replaceProgress.fail('$error');
      return ExitCode.software.code;
    }

    final buildProgress = logger.progress(
      'Building host (${previewConfig.assembleTask})',
    );
    try {
      final gradlewName = platform.isWindows ? 'gradlew.bat' : 'gradlew';
      final gradlewFile = File(p.join(hostProject.path, gradlewName));
      if (!gradlewFile.existsSync()) {
        throw Exception('Could not find $gradlewName in ${hostProject.path}');
      }
      if (!platform.isWindows) {
        await process.run('chmod', ['+x', gradlewFile.path]);
      }
      final exitCode = await process.stream(
        gradlewFile.path,
        [previewConfig.assembleTask],
        runInShell: false,
        workingDirectory: hostProject.path,
      );
      if (exitCode != ExitCode.success.code) {
        throw Exception(
          'gradlew ${previewConfig.assembleTask} failed ($exitCode)',
        );
      }
      buildProgress.complete();
    } on Exception catch (error) {
      buildProgress.fail('$error');
      return ExitCode.software.code;
    }

    final apk = findNewestHostApk(hostProject);
    if (apk == null) {
      logger.err(
        'Could not find a host APK under ${hostProject.path} after build.',
      );
      return ExitCode.software.code;
    }

    logger.info(
      'This will reinstall the host app and clear its data on the device.',
    );
    final installProgress = logger.progress('Installing host apk');
    try {
      await adb.installApk(apkPath: apk.path, deviceId: deviceId);
      await adb.clearAppData(
        package: previewConfig.applicationId,
        deviceId: deviceId,
      );
      await adb.startApp(
        package: previewConfig.applicationId,
        deviceId: deviceId,
      );
      installProgress.complete();
    } on Exception catch (error) {
      installProgress.fail('$error');
      return ExitCode.software.code;
    }

    final logProcess = await adb.logcat(filter: 'flutter', deviceId: deviceId);
    const decoder = Utf8Decoder(allowMalformed: true);
    logProcess.stdout.listen((event) {
      logger.info(decoder.convert(event));
    });
    logProcess.stderr.listen((event) {
      logger.err(decoder.convert(event));
    });
    return logProcess.exitCode;
  }

  /// Downloads an `xcframework`, replaces `App.xcframework` in the host iOS
  /// project configured under `shorebird.yaml` → `preview.ios` (or top-level
  /// `ios`), builds the host, and installs it on a device.
  Future<int> installAndLaunchIosModule({
    required String appId,
    required Release release,
    required DeploymentTrack track,
    required ShorebirdYaml? shorebirdYaml,
    String? deviceId,
  }) async {
    final configRoot =
        shorebirdEnv.getShorebirdProjectRoot() ?? Directory.current;
    final previewConfig = requireIosPreviewConfig(
      yaml: shorebirdYaml,
      logger: logger,
      configRoot: configRoot,
    );
    if (previewConfig == null) {
      return ExitCode.usage.code;
    }
    final hostProject = Directory(
      resolvePreviewPath(
        path: previewConfig.hostProject,
        configRoot: configRoot,
      ),
    );
    final frameworksDir = Directory(
      resolvePreviewPath(
        path: previewConfig.frameworksDir,
        configRoot: configRoot,
      ),
    );

    if (!hostProject.existsSync()) {
      logger.err('Host project not found: ${hostProject.path}');
      return ExitCode.config.code;
    }
    if (!frameworksDir.existsSync()) {
      frameworksDir.createSync(recursive: true);
    }

    late final ReleaseArtifact releaseXcframeworkArtifact;
    try {
      releaseXcframeworkArtifact = await codePushClientWrapper
          .getReleaseArtifact(
            appId: appId,
            releaseId: release.id,
            arch: 'xcframework',
            platform: ReleasePlatform.ios,
          );
    } on Exception catch (e, s) {
      logger
        ..err('Error getting release artifact: $e')
        ..detail('Stack trace: $s');
      return ExitCode.software.code;
    }

    late final File archiveFile;
    try {
      final cachedZip = File(
        getArtifactPath(
          appId: appId,
          release: release,
          artifact: releaseXcframeworkArtifact,
          platform: ReleasePlatform.ios,
          fileExtension: 'zip',
        ),
      );
      if (!cachedZip.existsSync()) {
        cachedZip.createSync(recursive: true);
        await artifactManager.downloadWithProgressUpdates(
          Uri.parse(releaseXcframeworkArtifact.url),
          message: 'Downloading xcframework',
          outputPath: cachedZip.path,
        );
      }
      archiveFile = cachedZip;
    } on Exception catch (error) {
      logger.err('$error');
      return ExitCode.software.code;
    }

    final appXcframework = Directory(
      p.join(frameworksDir.path, 'App.xcframework'),
    );
    final replaceProgress = logger.progress('Replacing App.xcframework');
    try {
      if (appXcframework.existsSync()) {
        appXcframework.deleteSync(recursive: true);
      }
      appXcframework.createSync(recursive: true);
      await artifactManager.extractZip(
        zipFile: archiveFile,
        outputDirectory: appXcframework,
      );
      replaceProgress.complete();
    } on Exception catch (error) {
      replaceProgress.fail('$error');
      return ExitCode.software.code;
    }

    final channelProgress = logger.progress('Using $track track');
    try {
      await setChannelOnXcframework(
        xcframeworkDirectory: appXcframework,
        channel: track.channel,
      );
      channelProgress.complete();
    } on Exception catch (error) {
      channelProgress.fail('$error');
      return ExitCode.software.code;
    }

    final deviceLocateProgress = logger.progress('Locating device for run');
    AppleDevice? deviceForLaunch;
    try {
      if (deviceId != null) {
        final devices = await devicectl.listAvailableIosDevices();
        deviceForLaunch = devices.firstWhereOrNull((d) => d.udid == deviceId);
      } else {
        deviceForLaunch = await devicectl.deviceForLaunch();
      }
    } on Exception catch (error, stackTrace) {
      logger.detail('devicectl device lookup failed: $error $stackTrace');
    }

    final destinationId = deviceForLaunch?.udid ?? deviceId;
    if (destinationId == null) {
      deviceLocateProgress.fail('No iOS device found for preview.');
      return ExitCode.software.code;
    }
    deviceLocateProgress.complete(
      deviceForLaunch != null
          ? 'Using device ${deviceForLaunch.name}'
          : 'Using device $destinationId',
    );

    final derivedData = Directory.systemTemp.createTempSync(
      'shorebird_module_preview_',
    );
    final buildProgress = logger.progress(
      'Building host (${previewConfig.scheme}/${previewConfig.configuration})',
    );
    try {
      final targetArgs = resolveXcodeBuildTargetArgs(
        hostProject: hostProject,
        config: previewConfig,
      );
      final exitCode = await process.stream(
        XcodeBuild.executable,
        [
          ...targetArgs,
          '-scheme',
          previewConfig.scheme,
          '-configuration',
          previewConfig.configuration,
          '-destination',
          'id=$destinationId',
          '-derivedDataPath',
          derivedData.path,
          'build',
        ],
        runInShell: false,
        workingDirectory: hostProject.path,
      );
      if (exitCode != ExitCode.success.code) {
        throw Exception('xcodebuild failed ($exitCode)');
      }
      buildProgress.complete();
    } on Exception catch (error) {
      buildProgress.fail('$error');
      return ExitCode.software.code;
    }

    final builtApp = findBuiltIosApp(
      derivedData: derivedData,
      configuration: previewConfig.configuration,
    );
    if (builtApp == null) {
      logger.err('Could not find a built .app under ${derivedData.path}');
      return ExitCode.software.code;
    }

    logger.info(
      'This will reinstall the host app and clear its data on the device.',
    );
    try {
      if (deviceForLaunch != null) {
        return await devicectl.installAndLaunchApp(
          runnerAppDirectory: builtApp,
          device: deviceForLaunch,
        );
      }
      await iosDeploy.installIfNeeded();
      return await iosDeploy.installAndLaunchApp(
        bundlePath: builtApp.path,
        deviceId: destinationId,
      );
    } on Exception catch (error, stackTrace) {
      logger.detail('Error launching host app. $error $stackTrace');
      return ExitCode.software.code;
    }
  }

  /// Downloads and runs the given [release] the given [appId] on Linux.
  // TODO(eseidel): Unlike mobile, desktop preview doesn't clear app state
  // or previously downloaded patches. Consider clearing state to match
  // the mobile behavior.
  Future<int> installAndLaunchLinux({
    required String appId,
    required Release release,
    required DeploymentTrack track,
  }) async {
    const platform = ReleasePlatform.linux;
    late Directory appDirectory;
    late ReleaseArtifact releaseArtifact;

    try {
      releaseArtifact = await codePushClientWrapper.getReleaseArtifact(
        appId: appId,
        releaseId: release.id,
        arch: 'bundle',
        platform: platform,
      );
    } on Exception catch (e, s) {
      logger
        ..err('Error getting release artifact: $e')
        ..detail('Stack trace: $s');
      return ExitCode.software.code;
    }

    appDirectory = Directory(
      getArtifactPath(
        appId: appId,
        release: release,
        artifact: releaseArtifact,
        platform: platform,
      ),
    );

    if (!appDirectory.existsSync()) {
      try {
        if (!appDirectory.existsSync()) {
          appDirectory.createSync(recursive: true);
        }

        final archiveFile = await artifactManager.downloadWithProgressUpdates(
          Uri.parse(releaseArtifact.url),
          message: 'Downloading ${releaseArtifact.arch}',
        );
        await artifactManager.extractZip(
          zipFile: archiveFile,
          outputDirectory: appDirectory,
        );
      } on Exception catch (error) {
        logger.err('$error');
        return ExitCode.software.code;
      }
    }

    final progress = logger.progress('Using $track track');
    try {
      await setChannelOnLinuxApp(
        channel: track.channel,
        bundleDirectory: appDirectory,
      );
      progress.complete();
    } on Exception catch (error) {
      progress.fail('$error');
      return ExitCode.software.code;
    }

    final executableFile = appDirectory.listSync().whereType<File>().first;

    await process.run('chmod', ['+x', executableFile.path]);

    return startAndForwardOutput(executableFile.path);
  }

  /// Downloads and runs the given [release] the given [appId] on Windows.
  // TODO(eseidel): Unlike mobile, desktop preview doesn't clear app state
  // or previously downloaded patches. Consider clearing state to match
  // the mobile behavior.
  Future<int> installAndLaunchWindows({
    required String appId,
    required Release release,
    required DeploymentTrack track,
  }) async {
    const platform = ReleasePlatform.windows;
    late Directory appDirectory;
    late ReleaseArtifact releaseExeArtifact;

    try {
      releaseExeArtifact = await codePushClientWrapper.getReleaseArtifact(
        appId: appId,
        releaseId: release.id,
        arch: primaryWindowsReleaseArtifactArch,
        platform: platform,
      );
    } on Exception catch (e, s) {
      logger
        ..err('Error getting release artifact: $e')
        ..detail('Stack trace: $s');
      return ExitCode.software.code;
    }

    appDirectory = Directory(
      getArtifactPath(
        appId: appId,
        release: release,
        artifact: releaseExeArtifact,
        platform: platform,
        fileExtension: 'exe',
      ),
    );

    if (!appDirectory.existsSync()) {
      try {
        if (!appDirectory.existsSync()) {
          appDirectory.createSync(recursive: true);
        }

        final archiveFile = await artifactManager.downloadWithProgressUpdates(
          Uri.parse(releaseExeArtifact.url),
          message: 'Downloading ${releaseExeArtifact.arch}',
        );
        await artifactManager.extractZip(
          zipFile: archiveFile,
          outputDirectory: appDirectory,
        );
      } on Exception catch (error) {
        logger.err('$error');
        return ExitCode.software.code;
      }
    }

    await setChannelOnWindowsApp(
      appDirectory: appDirectory,
      channel: track.channel,
    );

    final exeFile = windows.findExecutable(
      releaseDirectory: appDirectory,
    );

    return startAndForwardOutput(exeFile.path);
  }

  /// Installs and launches the release on macOS.
  // TODO(eseidel): Unlike mobile, desktop preview doesn't clear app state
  // or previously downloaded patches. Consider clearing state to match
  // the mobile behavior.
  Future<int> installAndLaunchMacos({
    required String appId,
    required Release release,
    required DeploymentTrack track,
  }) async {
    const platform = ReleasePlatform.macos;
    late Directory appDirectory;
    late ReleaseArtifact releaseRunnerArtifact;

    try {
      releaseRunnerArtifact = await codePushClientWrapper.getReleaseArtifact(
        appId: appId,
        releaseId: release.id,
        arch: 'app',
        platform: platform,
      );
    } on Exception catch (e, s) {
      logger
        ..err('Error getting release artifact: $e')
        ..detail('Stack trace: $s');
      return ExitCode.software.code;
    }

    appDirectory = Directory(
      getArtifactPath(
        appId: appId,
        release: release,
        artifact: releaseRunnerArtifact,
        platform: platform,
        fileExtension: 'app',
      ),
    );

    if (!appDirectory.existsSync()) {
      try {
        if (!appDirectory.existsSync()) {
          appDirectory.createSync(recursive: true);
        }

        final archiveFile = await artifactManager.downloadWithProgressUpdates(
          Uri.parse(releaseRunnerArtifact.url),
          message: 'Downloading ${releaseRunnerArtifact.arch}',
        );
        await ditto.extract(
          source: archiveFile.path,
          destination: appDirectory.path,
        );
      } on Exception catch (error) {
        logger.err('$error');
        return ExitCode.software.code;
      }
    }

    await setChannelOnMacosApp(
      appDirectory: appDirectory,
      channel: track.channel,
    );

    final logs = await open.newApplication(path: appDirectory.path);
    final completer = Completer<void>();

    // Filter out extra noise from the logs.
    final logFilters = [
      RegExp(r'\[com\.apple.*\]'),
      RegExp(r'\(RunningBoardServices\)'),
      RegExp(r'\(CoreFoundation\)'),
      RegExp(r'\(TCC\)'),
      RegExp(r'\(Metal\)'),
      RegExp('^Timestamp'),
      RegExp('^Filtering the log data'),
    ];

    // Removes the log prefix from the log line.
    // Example log line:
    // ignore: lines_longer_than_80_chars
    // 2025-01-31 09:53:22.889 Df macos_sandbox[22535:1d268] [dev.shorebird:updater::cache::patch_manager] [shorebird] No public key provided, skipping signature verification
    final prefixRegex = RegExp(
      r'^[\d-]+\W+[\d:\.]+\W+\w+\W+\w+\[[\da-f]+:[\da-f]+\]',
    );
    String removeLogPrefix(String line) {
      return line.trim().replaceFirst(prefixRegex, '').trim();
    }

    // TODO(eseidel): Use startAndForwardOutput instead?
    // This doesn't seem to handle stderr, maybe it should?
    // Use allowMalformed to handle non-UTF8 bytes in log stream output.
    const decoder = Utf8Decoder(allowMalformed: true);
    logs.listen((log) {
      final logLine = decoder.convert(log);
      if (logFilters.any((filter) => filter.hasMatch(logLine))) {
        return;
      }

      logger.info(removeLogPrefix(logLine));
    }, onDone: completer.complete);

    return completer.future.then((_) => ExitCode.success.code);
  }

  /// Installs and launches the release on Android.
  Future<int> installAndLaunchAndroid({
    required String appId,
    required Release release,
    required DeploymentTrack track,
    String? deviceId,
  }) async {
    const platform = ReleasePlatform.android;

    final keystore = results['ks'] as String?;
    final keystorePassword = results['ks-pass'] as String?;
    final keyPassword = results['ks-key-pass'] as String?;
    final keyAlias = results['ks-key-alias'] as String?;

    // Ensure keystore options are valid.
    if (keystore != null) {
      if (keystorePassword == null) {
        logger.err('You must provide a keystore password.');
        return ExitCode.usage.code;
      }
      if (keyAlias == null) {
        logger.err('You must provide a key alias.');
        return ExitCode.usage.code;
      }

      if (!keystorePassword.startsWith('pass:') &&
          !keystorePassword.startsWith('file:')) {
        logger.err('Keystore password must start with "pass:" or "file:".');
        return ExitCode.usage.code;
      }

      if (keyPassword != null &&
          !keyPassword.startsWith('pass:') &&
          !keyPassword.startsWith('file:')) {
        logger.err('Key password must start with "pass:" or "file:".');
        return ExitCode.usage.code;
      }
    }

    late File aabFile;
    late ReleaseArtifact releaseAabArtifact;

    try {
      releaseAabArtifact = await codePushClientWrapper.getReleaseArtifact(
        appId: appId,
        releaseId: release.id,
        arch: 'aab',
        platform: platform,
      );
    } on Exception catch (e, s) {
      logger
        ..err('Error getting release artifact: $e')
        ..detail('Stack trace: $s');
      return ExitCode.software.code;
    }

    try {
      aabFile = File(
        getArtifactPath(
          appId: appId,
          release: release,
          artifact: releaseAabArtifact,
          platform: platform,
          fileExtension: 'aab',
        ),
      );

      if (!aabFile.existsSync()) {
        aabFile.createSync(recursive: true);

        await artifactManager.downloadWithProgressUpdates(
          Uri.parse(releaseAabArtifact.url),
          message: 'Downloading ${releaseAabArtifact.arch}',
          outputPath: aabFile.path,
        );
      }
    } on Exception catch (error) {
      logger.err('$error');
      return ExitCode.software.code;
    }

    final apksPath = getArtifactPath(
      appId: appId,
      release: release,
      artifact: releaseAabArtifact,
      platform: platform,
      fileExtension: 'apks',
    );

    if (File(apksPath).existsSync()) File(apksPath).deleteSync();
    final progress = logger.progress('Using $track track');
    try {
      await setChannelOnAab(aabFile: aabFile, channel: track.channel);
      progress.complete();
    } on Exception catch (error) {
      progress.fail('$error');
      return ExitCode.software.code;
    }

    final extractMetadataProgress = logger.progress('Extracting metadata');
    late String package;
    try {
      package = await bundletool.getPackageName(aabFile.path);
      extractMetadataProgress.complete();
    } on Exception catch (error) {
      extractMetadataProgress.fail('$error');
      return ExitCode.software.code;
    }

    final buildApksProgress = logger.progress('Building apks');
    try {
      await bundletool.buildApks(
        bundle: aabFile.path,
        output: apksPath,
        keystore: keystore,
        keystorePassword: keystorePassword,
        keyPassword: keyPassword,
        keyAlias: keyAlias,
      );
      final apksLink = link(uri: Uri.parse(apksPath));
      buildApksProgress.complete('Built apks: ${cyan.wrap(apksLink)}');
    } on Exception catch (error) {
      buildApksProgress.fail('$error');
      return ExitCode.software.code;
    }

    logger.info(
      'This will reinstall the app and clear its data on the device.',
    );
    final installApksProgress = logger.progress('Installing apks');
    try {
      await bundletool.installApks(apks: apksPath, deviceId: deviceId);
      installApksProgress.complete();
    } on Exception catch (error) {
      installApksProgress.fail('$error');
      return ExitCode.software.code;
    }

    final startAppProgress = logger.progress('Starting app');
    try {
      await adb.clearAppData(package: package, deviceId: deviceId);
      await adb.startApp(package: package, deviceId: deviceId);
      startAppProgress.complete();
    } on Exception catch (error) {
      startAppProgress.fail('$error');
      return ExitCode.software.code;
    }

    final process = await adb.logcat(filter: 'flutter', deviceId: deviceId);
    // adb logcat sometimes lets non-utf8 characters through, so we need to
    // not crash when it does.
    const decoder = Utf8Decoder(allowMalformed: true);
    process.stdout.listen((event) {
      logger.info(decoder.convert(event));
    });
    process.stderr.listen((event) {
      logger.err(decoder.convert(event));
    });

    return process.exitCode;
  }

  /// Installs and launches the release on iOS.
  Future<int> installAndLaunchIos({
    required String appId,
    required Release release,
    required DeploymentTrack track,
    String? deviceId,
  }) async {
    // ios-deploy is only needed for the iOS 16- fallback path. Installing it
    // eagerly requires a local Flutter SDK (`flutter precache --ios`) and
    // breaks iOS 17+ previews that use devicectl when that SDK is missing.
    const platform = ReleasePlatform.ios;
    late Directory runnerDirectory;
    late ReleaseArtifact releaseRunnerArtifact;

    try {
      releaseRunnerArtifact = await codePushClientWrapper.getReleaseArtifact(
        appId: appId,
        releaseId: release.id,
        arch: 'runner',
        platform: platform,
      );
    } on Exception catch (e, s) {
      logger
        ..err('Error getting release artifact: $e')
        ..detail('Stack trace: $s');
      return ExitCode.software.code;
    }

    runnerDirectory = Directory(
      getArtifactPath(
        appId: appId,
        release: release,
        artifact: releaseRunnerArtifact,
        platform: platform,
        fileExtension: 'app',
      ),
    );

    if (!runnerDirectory.existsSync()) {
      try {
        if (!runnerDirectory.existsSync()) {
          runnerDirectory.createSync(recursive: true);
        }

        final archiveFile = await artifactManager.downloadWithProgressUpdates(
          Uri.parse(releaseRunnerArtifact.url),
          message: 'Downloading ${releaseRunnerArtifact.arch}',
        );
        await artifactManager.extractZip(
          zipFile: archiveFile,
          outputDirectory: runnerDirectory,
        );
      } on Exception catch (error) {
        logger.err('$error');
        return ExitCode.software.code;
      }
    }

    final progress = logger.progress('Using $track track');
    try {
      await setChannelOnRunner(
        runnerDirectory: runnerDirectory,
        channel: track.channel,
      );
      progress.complete();
    } on Exception catch (error) {
      progress.fail('$error');
      return ExitCode.software.code;
    }

    try {
      final deviceLocateProgress = logger.progress('Locating device for run');
      final AppleDevice? deviceForLaunch;
      // Try to find a device using devicectl first. If that fails, fall back to
      // ios-deploy.
      if (deviceId != null) {
        final deviceCtlDevices = await devicectl.listAvailableIosDevices();
        deviceForLaunch = deviceCtlDevices.firstWhereOrNull(
          (device) => device.udid == deviceId,
        );
      } else {
        deviceForLaunch = await devicectl.deviceForLaunch();
      }

      final shouldUseDeviceCtl = deviceForLaunch != null;

      // Before falling back to ios-deploy, check if devicectl knows about a
      // matching iOS 17+ device that is paired but currently unreachable
      // (locked, screen off, or off the local network when wireless debugging
      // is in use). ios-deploy does not work with iOS 17 or later, so the
      // fallback would just produce an opaque failure. Surface a hint
      // instead.
      if (!shouldUseDeviceCtl) {
        final unreachable = await _findUnreachableIos17OrLaterDevice(
          deviceId: deviceId,
        );
        if (unreachable != null) {
          deviceLocateProgress.fail(
            '${unreachable.name} (iOS '
            '${unreachable.osVersionString ?? 'unknown'}) is paired but '
            'currently unreachable.',
          );
          logger.info(
            '''
This usually means the device is locked, or that wireless debugging dropped because the screen turned off.

To preview on this device:
  • Connect it via USB, or
  • Unlock the device and make sure it is on the same Wi-Fi network as this Mac.

Skipping the ios-deploy fallback because it does not support iOS 17 or later.''',
          );
          return ExitCode.software.code;
        }
      }

      final progressCompleteMessage = deviceForLaunch != null
          ? 'Using device ${deviceForLaunch.name}'
          : '''No iOS 17+ device found, looking for devices running iOS 16 or lower''';
      deviceLocateProgress.complete(progressCompleteMessage);

      logger.info(
        'This will reinstall the app and clear its data on the device.',
      );
      final int installExitCode;
      if (shouldUseDeviceCtl) {
        logger.detail(
          '''Using devicectl to install and launch on device ${deviceForLaunch.udid}.''',
        );
        installExitCode = await devicectl.installAndLaunchApp(
          runnerAppDirectory: runnerDirectory,
          device: deviceForLaunch,
        );
      } else {
        logger.detail('Using ios-deploy to install and launch.');
        await iosDeploy.installIfNeeded();
        installExitCode = await iosDeploy.installAndLaunchApp(
          bundlePath: runnerDirectory.path,
          deviceId: deviceId,
        );
      }

      return installExitCode;
    } on Exception catch (error, stackTrace) {
      logger.detail('Error launching app. $error $stackTrace');
      return ExitCode.software.code;
    }
  }

  /// Returns a paired iOS 17+ device that devicectl knows about but cannot
  /// currently reach (e.g. locked, screen off, off Wi-Fi while wireless
  /// debugging), or `null` if no such device exists. When [deviceId] is
  /// provided, only a device with that UDID is considered.
  ///
  /// If devicectl can't be queried for any reason, returns `null` so the
  /// caller can fall through to its existing behavior rather than surface a
  /// hint based on partial information.
  Future<AppleDevice?> _findUnreachableIos17OrLaterDevice({
    String? deviceId,
  }) async {
    final List<AppleDevice> all;
    try {
      all = await devicectl.listAllIosDevices();
    } on Exception catch (error, stackTrace) {
      logger.detail('listAllIosDevices failed: $error $stackTrace');
      return null;
    }

    final unreachableModern = all.where((device) {
      if (device.isAvailable) return false;
      final version = device.osVersion;
      return version != null && version.major >= 17;
    });

    if (deviceId != null) {
      return unreachableModern.firstWhereOrNull((d) => d.udid == deviceId);
    }
    return unreachableModern.firstOrNull;
  }

  /// Resolves the artifact path for the given parameters.
  String getArtifactPath({
    required String appId,
    required Release release,
    required ReleaseArtifact artifact,
    required ReleasePlatform platform,
    String? fileExtension,
  }) {
    final previewDirectory = cache.getPreviewDirectory(appId);
    final ext = fileExtension != null ? '.$fileExtension' : '';
    return p.join(
      previewDirectory.path,
      '${platform.name}_${release.version}_${artifact.id}$ext',
    );
  }

  /// Sets the channel property in the shorebird.yaml file inside the Windows
  /// app whose root directory is [appDirectory].
  Future<void> setChannelOnWindowsApp({
    required Directory appDirectory,
    required String channel,
  }) async {
    final shorebirdYamlFile = File(
      p.join(appDirectory.path, 'data', 'flutter_assets', 'shorebird.yaml'),
    );

    await _maybeSetChannelInShorebirdYaml(
      channel: channel,
      shorebirdYamlFile: shorebirdYamlFile,
    );
  }

  /// Sets the channel property in the shorebird.yaml file inside the Runner.app
  Future<void> setChannelOnRunner({
    required Directory runnerDirectory,
    required String channel,
  }) async {
    await Isolate.run(() async {
      final shorebirdYaml = File(
        p.join(
          runnerDirectory.path,
          'Frameworks',
          'App.framework',
          'flutter_assets',
          'shorebird.yaml',
        ),
      );

      if (!shorebirdYaml.existsSync()) {
        throw Exception('Unable to find shorebird.yaml');
      }

      await _maybeSetChannelInShorebirdYaml(
        channel: channel,
        shorebirdYamlFile: shorebirdYaml,
      );
    });
  }

  /// Sets the channel property in the shorebird.yaml file inside a macOS app.
  Future<void> setChannelOnMacosApp({
    required Directory appDirectory,
    required String channel,
  }) async {
    final shorebirdYamlFile = File(
      p.join(
        appDirectory.path,
        'Contents',
        'Frameworks',
        'App.framework',
        'Resources',
        'flutter_assets',
        'shorebird.yaml',
      ),
    );

    await _maybeSetChannelInShorebirdYaml(
      channel: channel,
      shorebirdYamlFile: shorebirdYamlFile,
    );
  }

  /// Unzips a Flutter module `.aar`, sets `channel` in
  /// `assets/flutter_assets/shorebird.yaml`, and re-zips the archive.
  Future<void> setChannelOnAar({
    required File aarFile,
    required String channel,
  }) async {
    final extractZip = artifactManager.extractZip;

    await Isolate.run(() async {
      final tempDir = Directory.systemTemp.createTempSync();
      final outputPath = p.join(tempDir.path, 'tmp.aar.contents');

      await extractZip(
        zipFile: aarFile,
        outputDirectory: Directory(outputPath),
      );

      final shorebirdYamlFile = File(
        p.join(outputPath, 'assets', 'flutter_assets', 'shorebird.yaml'),
      );

      final didUpdate = await _maybeSetChannelInShorebirdYaml(
        channel: channel,
        shorebirdYamlFile: shorebirdYamlFile,
      );
      if (!didUpdate) {
        tempDir.deleteSync(recursive: true);
        return;
      }

      final tmpAarFile = File(p.join(tempDir.path, p.basename(aarFile.path)));
      final encoder = ZipFileEncoder()..create(tmpAarFile.path);
      for (final file in Directory(outputPath).listSync(recursive: true)) {
        if (file is File) {
          await encoder.addFile(
            file,
            file.path.replaceFirst('$outputPath${p.separator}', ''),
          );
        }
      }
      await encoder.close();

      tmpAarFile.copySync(aarFile.path);
      tempDir.deleteSync(recursive: true);
    });
  }

  /// Sets `channel` on every `flutter_assets/shorebird.yaml` found under an
  /// `App.xcframework` directory.
  Future<void> setChannelOnXcframework({
    required Directory xcframeworkDirectory,
    required String channel,
  }) async {
    final yamlFiles = xcframeworkDirectory
        .listSync(recursive: true)
        .whereType<File>()
        .where(
          (f) =>
              p.basename(f.path) == 'shorebird.yaml' &&
              p.basename(p.dirname(f.path)) == 'flutter_assets',
        )
        .toList();

    if (yamlFiles.isEmpty) {
      throw Exception(
        'Unable to find shorebird.yaml under ${xcframeworkDirectory.path}',
      );
    }

    for (final yamlFile in yamlFiles) {
      await _maybeSetChannelInShorebirdYaml(
        channel: channel,
        shorebirdYamlFile: yamlFile,
      );
    }
  }

  /// Unzips the `.aab` and sets the channel property in the shorebird.yaml
  /// file inside the base module and then re-zips the `.aab`.
  Future<void> setChannelOnAab({
    required File aabFile,
    required String channel,
  }) async {
    // Getting the reference here since we cannot inside the isolate.
    final extractZip = artifactManager.extractZip;

    await Isolate.run(() async {
      final tempDir = Directory.systemTemp.createTempSync();
      final outputPath = p.join(tempDir.path, 'tmp.aab');

      await extractZip(
        zipFile: aabFile,
        outputDirectory: Directory(outputPath),
      );

      final shorebirdYamlFile = File(
        p.join(
          outputPath,
          'base',
          'assets',
          'flutter_assets',
          'shorebird.yaml',
        ),
      );

      final didUpdateShorebirdYaml = await _maybeSetChannelInShorebirdYaml(
        channel: channel,
        shorebirdYamlFile: shorebirdYamlFile,
      );

      if (!didUpdateShorebirdYaml) {
        return;
      }

      // This is equivalent to `zip --no-dir-entries`
      // Which does NOT create entries in the zip archive for directories.
      // It's important to do this because bundletool expects the
      // .aab not to contain any directories.
      final tmpAabFile = File(p.join(tempDir.path, p.basename(aabFile.path)));
      final encoder = ZipFileEncoder()..create(tmpAabFile.path);
      for (final file in Directory(outputPath).listSync(recursive: true)) {
        if (file is File) {
          await encoder.addFile(
            file,
            file.path.replaceFirst('$outputPath${p.separator}', ''),
          );
        }
      }
      await encoder.close();

      // Replace the existing preview artifact with the updated one.
      tmpAabFile.copySync(aabFile.path);
      tempDir.deleteSync(recursive: true);
    });
  }

  /// Sets the channel property in the shorebird.yaml file if none is set.
  Future<void> setChannelOnLinuxApp({
    required String channel,
    required Directory bundleDirectory,
  }) async {
    final shorebirdYamlFile = File(
      p.join(bundleDirectory.path, 'data', 'flutter_assets', 'shorebird.yaml'),
    );

    await _maybeSetChannelInShorebirdYaml(
      channel: channel,
      shorebirdYamlFile: shorebirdYamlFile,
    );
  }

  /// Sets the channel property in the shorebird.yaml file if none is set or
  /// different from the provided channel.
  static Future<bool> _maybeSetChannelInShorebirdYaml({
    required String channel,
    required File shorebirdYamlFile,
  }) async {
    if (!shorebirdYamlFile.existsSync()) {
      throw Exception('Unable to find shorebird.yaml');
    }

    final yamlText = shorebirdYamlFile.readAsStringSync();
    final yaml = loadYaml(yamlText) as YamlMap;
    final yamlChannel = yaml['channel'];

    if (yamlChannel == null && channel == DeploymentTrack.stable.channel) {
      // We would be updating the channel to the default value.
      return false;
    }

    if (yamlChannel == channel) {
      // Updating this channel would be a no-op.
      return false;
    }

    final yamlEditor = YamlEditor(yamlText)..update(['channel'], channel);
    shorebirdYamlFile.writeAsStringSync(yamlEditor.toString(), flush: true);
    return true;
  }

  /// Starts a process and forwards its stdout/stderr to the logger.
  ///
  /// Returns the process exit code.
  Future<int> startAndForwardOutput(String executable) async {
    final proc = await process.start(executable, []);
    // Use allowMalformed to handle non-UTF8 bytes in process output.
    const decoder = Utf8Decoder(allowMalformed: true);
    proc.stdout.listen((log) => logger.info(decoder.convert(log)));
    proc.stderr.listen((log) => logger.err(decoder.convert(log)));
    return proc.exitCode;
  }
}

/// Extension on [Release] that exposes the active platforms (e.g. platforms
/// that can be previewed).
extension Previewable on Release {
  /// Returns the platforms that can be previewed.
  List<ReleasePlatform> get activePlatforms => platformStatuses.entries
      .where((e) => e.value == ReleaseStatus.active)
      .map((e) => e.key)
      .toList();
}

/// Given two [Release]s, one with all the platforms, previewable or not,
/// and one with only the previewable platforms, this method will check for
/// platforms that are not previewable.
///
/// If any non-previewable platforms are found, we will:
/// - Warn the user about the platform if that platform is not the one
///    the user specified with `--platform`.
/// - Error out if the user specified a platform that is not previewable.
void assertPreviewableReleases({
  required Release releaseWithAllPlatforms,
  required Release release,
  required ReleasePlatform? targetPlatform,
}) {
  final nonPreviewablePlatforms = releaseWithAllPlatforms.activePlatforms.where(
    (p) => !release.activePlatforms.contains(p),
  );

  for (final platform in nonPreviewablePlatforms) {
    final message =
        '''The ${platform.displayName} artifact for this release is not previewable.''';

    // If the user explicitly specified a platform and it matches a non
    // previewable platform, we early exit to avoid duplicated warnings/errors.
    if (targetPlatform?.name == platform.name) {
      logger.err(message);
      throw ProcessExit(ExitCode.software.code);
      // We only WARN if the user didn't specify a platform.
    } else if (targetPlatform == null) {
      logger.warn(message);
    }
  }
}
