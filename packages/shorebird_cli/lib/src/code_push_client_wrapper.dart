// cspell:words endtemplate pubspec sideloadable bryanoltman archs sideload
// cspell:words xcarchive codesigned xcframework

import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:equatable/equatable.dart';
import 'package:io/io.dart' as io;
import 'package:mason_logger/mason_logger.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/archive/directory_archive.dart';
import 'package:shorebird_cli/src/artifact_manager.dart';
import 'package:shorebird_cli/src/auth/auth.dart';
import 'package:shorebird_cli/src/cache.dart';
import 'package:shorebird_cli/src/deployment_track.dart';
import 'package:shorebird_cli/src/executables/executables.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform/platform.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_flutter.dart';
import 'package:shorebird_cli/src/third_party/flutter_tools/lib/flutter_tools.dart';
import 'package:shorebird_cli/src/version.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';

/// {@template patch_artifact_bundle}
/// Metadata about a patch artifact that we are about to upload.
/// {@endtemplate}
class PatchArtifactBundle extends Equatable {
  /// {@macro patch_artifact_bundle}
  const PatchArtifactBundle({
    required this.arch,
    required this.path,
    required this.hash,
    required this.size,
    this.hashSignature,
    this.podfileLockHash,
  });

  /// The corresponding architecture.
  final String arch;

  /// The path to the artifact.
  final String path;

  /// The artifact hash.
  final String hash;

  /// The size in bytes of the artifact.
  final int size;

  /// The signature of the artifact hash.
  final String? hashSignature;

  /// The hash of the Podfile.lock file, if present and relevant.
  final String? podfileLockHash;

  @override
  List<Object?> get props => [
    arch,
    path,
    hash,
    size,
    hashSignature,
    podfileLockHash,
  ];
}

/// A reference to a [CodePushClientWrapper] instance.
ScopedRef<CodePushClientWrapper> codePushClientWrapperRef = create(() {
  final hostedUri = shorebirdEnv.hostedUri;
  if (hostedUri == null) {
    throw StateError(
      'Missing base_url in shorebird.yaml. '
      'Add e.g. `base_url: http://127.0.0.1:8080` and re-run.',
    );
  }
  return CodePushClientWrapper(
    codePushClient: CodePushClient(
      httpClient: auth.client,
      hostedUri: hostedUri,
      customHeaders: {'x-cli-version': packageVersion},
      artifactCacheRoot: Cache.shorebirdFlutterpatchDirectory,
    ),
  );
});

/// The [CodePushClientWrapper] instance available in the current zone.
CodePushClientWrapper get codePushClientWrapper =>
    read(codePushClientWrapperRef);

/// {@template code_push_client_wrapper}
/// Wraps [CodePushClient] interaction with logging and error handling to
/// reduce the amount of command and command test code.
/// {@endtemplate}
class CodePushClientWrapper {
  /// {@macro code_push_client_wrapper}
  CodePushClientWrapper({required this.codePushClient});

  /// The underlying code push client.
  final CodePushClient codePushClient;

  /// Create an app with the given [organizationId] and [appName].
  Future<App> createApp({required int organizationId, String? appName}) async {
    late final String displayName;
    if (appName == null) {
      final defaultAppName = shorebirdEnv.getPubspecYaml()?.name;
      displayName = logger.prompt(
        '${lightGreen.wrap('?')} How should we refer to this app?',
        defaultValue: defaultAppName,
        hint:
            'Pass --display-name=<name> to set the app name without '
            'prompting.',
      );
    } else {
      displayName = appName;
    }

    return codePushClient.createApp(
      displayName: displayName,
      organizationId: organizationId,
    );
  }

  /// Fetches the currently authenticated user.
  Future<PrivateUser> getCurrentUser() async {
    final progress = logger.progress('Fetching account');
    final PrivateUser? user;
    try {
      user = await codePushClient.getCurrentUser();
      progress.complete();
    } catch (error) {
      _handleErrorAndExit(error, progress: progress);
    }
    if (user == null) {
      logger.err('Could not find current user.');
      throw ProcessExit(ExitCode.software.code);
    }
    return user;
  }

  /// Fetches the plan level for the current user, e.g. `free`, `pro`,
  /// `business` or `enterprise`. Null when the server does not report one.
  Future<String?> getPlanLevel() async {
    final progress = logger.progress('Fetching plan');
    final String? level;
    try {
      level = await codePushClient.getPlanLevel();
      progress.complete();
    } catch (error) {
      _handleErrorAndExit(error, progress: progress);
    }
    return level;
  }

  /// Fetches the organization memberships for the current user.
  Future<List<OrganizationMembership>> getOrganizationMemberships() async {
    final progress = logger.progress('Fetching organizations');
    final List<OrganizationMembership> memberships;
    try {
      memberships = await codePushClient.getOrganizationMemberships();
      progress.complete();
    } catch (error) {
      _handleErrorAndExit(error, progress: progress);
    }

    return memberships;
  }

  /// Fetches the apps for the current user.
  Future<List<AppMetadata>> getApps() async {
    final fetchAppsProgress = logger.progress('Fetching apps');
    try {
      final apps = await codePushClient.getApps();
      fetchAppsProgress.complete();
      return apps;
    } catch (error) {
      _handleErrorAndExit(error, progress: fetchAppsProgress);
    }
  }

  /// Returns [AppMetadata] for the provided [appId].
  Future<AppMetadata> getApp({required String appId}) async {
    final app = await maybeGetApp(appId: appId);
    if (app == null) {
      logger.err('''
Could not find app with id: "$appId".
This app may not exist or you may not have permission to view it.''');

      throw ProcessExit(ExitCode.software.code);
    }

    return app;
  }

  /// Returns [AppMetadata] for the provided [appId] or null if the app does not
  /// exist.
  Future<AppMetadata?> maybeGetApp({required String appId}) async {
    final apps = await getApps();
    return apps.firstWhereOrNull((a) => a.appId == appId);
  }

  /// Fetches the channels for the given [appId] and channel [name].
  /// Returns null if a channel does not exist.
  Future<Channel?> maybeGetChannel({
    required String appId,
    required String name,
  }) async {
    final fetchChannelsProgress = logger.progress('Fetching channels');
    try {
      final channels = await codePushClient.getChannels(appId: appId);
      final channel = channels.firstWhereOrNull(
        (channel) => channel.name == name,
      );
      fetchChannelsProgress.complete();
      return channel;
    } catch (error) {
      _handleErrorAndExit(error, progress: fetchChannelsProgress);
    }
  }

  /// Fetches all channels for the provided [appId].
  Future<List<Channel>> getChannels({required String appId}) async {
    final fetchChannelsProgress = logger.progress('Fetching channels');
    try {
      final channels = await codePushClient.getChannels(appId: appId);
      fetchChannelsProgress.complete();
      return channels;
    } catch (error) {
      _handleErrorAndExit(error, progress: fetchChannelsProgress);
    }
  }

  /// Creates a channel for the provided [appId] with the given [name].
  Future<Channel> createChannel({
    required String appId,
    required String name,
  }) async {
    final createChannelProgress = logger.progress('Creating channel');
    try {
      final channel = await codePushClient.createChannel(
        appId: appId,
        channel: name,
      );
      createChannelProgress.complete();
      return channel;
    } catch (error) {
      _handleErrorAndExit(error, progress: createChannelProgress);
    }
  }

  /// Deletes the channel with the provided [channelId] from [appId].
  Future<void> deleteChannel({
    required String appId,
    required int channelId,
  }) async {
    final deleteChannelProgress = logger.progress('Deleting channel');
    try {
      await codePushClient.deleteChannel(appId: appId, channelId: channelId);
      deleteChannelProgress.complete();
    } catch (error) {
      _handleErrorAndExit(error, progress: deleteChannelProgress);
    }
  }

  /// Renames the app with the provided [appId] to [displayName].
  Future<void> updateApp({
    required String appId,
    required String displayName,
  }) async {
    final updateAppProgress = logger.progress('Renaming app');
    try {
      await codePushClient.updateApp(appId: appId, displayName: displayName);
      updateAppProgress.complete();
    } catch (error) {
      _handleErrorAndExit(error, progress: updateAppProgress);
    }
  }

  /// Deletes the app with the provided [appId], along with every release and
  /// patch belonging to it.
  Future<void> deleteApp({required String appId}) async {
    final deleteAppProgress = logger.progress('Deleting app');
    try {
      await codePushClient.deleteApp(appId: appId);
      deleteAppProgress.complete();
    } catch (error) {
      _handleErrorAndExit(error, progress: deleteAppProgress);
    }
  }

  /// Moves the app with the provided [appId] into [organizationId].
  Future<void> transferApp({
    required int organizationId,
    required String appId,
  }) async {
    final transferAppProgress = logger.progress('Transferring app');
    try {
      await codePushClient.transferApp(
        organizationId: organizationId,
        appId: appId,
      );
      transferAppProgress.complete();
    } catch (error) {
      _handleErrorAndExit(error, progress: transferAppProgress);
    }
  }

  /// Prints an error message and exits with code 70 if [release] is in an
  /// active state for [platform].
  void ensureReleaseIsNotActive({
    required Release release,
    required ReleasePlatform platform,
  }) {
    if (release.platformStatuses[platform] == ReleaseStatus.active) {
      logger.err(
        '''
It looks like you have an existing ${platform.name} release for version ${lightCyan.wrap(release.version)}.
Please bump your version number and try again.''',
      );
      throw ProcessExit(ExitCode.software.code);
    }
  }

  /// Fetches the release for the given [appId] and [releaseVersion].
  Future<Release> getRelease({
    required String appId,
    required String releaseVersion,
  }) async {
    final release = await maybeGetRelease(
      appId: appId,
      releaseVersion: releaseVersion,
    );

    if (release == null) {
      logger.err('''
Release not found: "$releaseVersion"

Patches can only be published for existing releases.
Please create a release using "flutterpatch release" and try again.
''');
      throw ProcessExit(ExitCode.software.code);
    }

    return release;
  }

  /// Fetches the releases for the given [appId].
  Future<List<Release>> getReleases({
    required String appId,
    bool sideloadableOnly = false,
  }) async {
    final fetchReleasesProgress = logger.progress('Fetching releases');
    try {
      final releases = await codePushClient.getReleases(
        appId: appId,
        sideloadableOnly: sideloadableOnly,
      );
      fetchReleasesProgress.complete();
      return releases;
    } catch (error) {
      _handleErrorAndExit(error, progress: fetchReleasesProgress);
    }
  }

  /// Fetches the release for the given [appId] and [releaseVersion] or null if
  /// the release does not exist.
  Future<Release?> maybeGetRelease({
    required String appId,
    required String releaseVersion,
  }) async {
    final releases = await getReleases(appId: appId);
    return releases.firstWhereOrNull((r) => r.version == releaseVersion);
  }

  /// Gets the patches for [appId]'s [releaseId].
  Future<List<ReleasePatch>> getReleasePatches({
    required String appId,
    required int releaseId,
  }) async {
    final fetchReleasePatchesProgress = logger.progress('Fetching patches');
    try {
      final patches = await codePushClient.getPatches(
        appId: appId,
        releaseId: releaseId,
      );
      fetchReleasePatchesProgress.complete();
      return patches;
    } catch (error) {
      _handleErrorAndExit(error, progress: fetchReleasePatchesProgress);
    }
  }

  /// Creates a release for the given [appId], [version], [flutterRevision], and
  /// [platform].
  Future<Release> createRelease({
    required String appId,
    required String version,
    required String flutterRevision,
    required ReleasePlatform platform,
  }) async {
    final createReleaseProgress = logger.progress('Creating release');
    final flutterVersion = await shorebirdFlutter.getVersionForRevision(
      flutterRevision: flutterRevision,
    );
    try {
      final release = await codePushClient.createRelease(
        appId: appId,
        version: version,
        flutterRevision: flutterRevision,
        flutterVersion: flutterVersion,
      );
      await codePushClient.updateReleaseStatus(
        appId: appId,
        releaseId: release.id,
        platform: platform,
        status: ReleaseStatus.draft,
      );
      createReleaseProgress.complete();
      return release;
    } catch (error) {
      _handleErrorAndExit(error, progress: createReleaseProgress);
    }
  }

  /// Updates the status of a release for the given [appId], [releaseId],
  /// [platform], and [status].
  Future<void> updateReleaseStatus({
    required String appId,
    required int releaseId,
    required ReleasePlatform platform,
    required ReleaseStatus status,
    Json? metadata,
  }) async {
    final updateStatusProgress = logger.progress('Updating release status');
    try {
      await codePushClient.updateReleaseStatus(
        appId: appId,
        releaseId: releaseId,
        platform: platform,
        status: status,
        metadata: metadata,
      );
      updateStatusProgress.complete();
    } catch (error) {
      _handleErrorAndExit(error, progress: updateStatusProgress);
    }
  }

  /// Returns release artifacts for the given [appId], [releaseId],
  /// [architectures], and [platform]. Not all architectures may have artifacts,
  /// so the returned map may not contain all the requested architectures.
  Future<Map<Arch, ReleaseArtifact>> getReleaseArtifacts({
    required String appId,
    required int releaseId,
    required Iterable<Arch> architectures,
    required ReleasePlatform platform,
  }) async {
    // TODO(bryanoltman): update this function to only make one call to
    // getReleaseArtifacts.
    final releaseArtifacts = <Arch, ReleaseArtifact>{};
    final fetchReleaseArtifactProgress = logger.progress(
      'Fetching release artifacts',
    );
    for (final arch in architectures) {
      try {
        final artifacts = await codePushClient.getReleaseArtifacts(
          appId: appId,
          releaseId: releaseId,
          arch: arch.arch,
          platform: platform,
        );
        if (artifacts.isEmpty) {
          continue;
        }
        releaseArtifacts[arch] = artifacts.first;
      } catch (error) {
        _handleErrorAndExit(error, progress: fetchReleaseArtifactProgress);
      }
    }

    fetchReleaseArtifactProgress.complete();
    return releaseArtifacts;
  }

  /// Returns a release artifact for the given [appId], [releaseId], [arch], and
  /// [platform].
  /// Throws a [CodePushNotFoundException] if no artifact is found.
  Future<ReleaseArtifact> getReleaseArtifact({
    required String appId,
    required int releaseId,
    required String arch,
    required ReleasePlatform platform,
  }) async {
    final fetchReleaseArtifactProgress = logger.progress(
      'Fetching $arch artifact',
    );
    try {
      final artifacts = await codePushClient.getReleaseArtifacts(
        appId: appId,
        releaseId: releaseId,
        arch: arch,
        platform: platform,
      );
      if (artifacts.isEmpty) {
        throw CodePushNotFoundException(
          message:
              '''No artifact found for architecture $arch in release $releaseId''',
        );
      }
      fetchReleaseArtifactProgress.complete();
      return artifacts.first;
    } catch (error) {
      _handleErrorAndExit(error, progress: fetchReleaseArtifactProgress);
    }
  }

  /// Fetches a release artifact for the given [appId], [releaseId], [arch], and
  /// [platform]. Returns null if no artifact is found.
  Future<ReleaseArtifact?> maybeGetReleaseArtifact({
    required String appId,
    required int releaseId,
    required String arch,
    required ReleasePlatform platform,
  }) async {
    final fetchReleaseArtifactProgress = logger.progress(
      'Fetching $arch artifact',
    );
    try {
      final artifacts = await codePushClient.getReleaseArtifacts(
        appId: appId,
        releaseId: releaseId,
        arch: arch,
        platform: platform,
      );
      if (artifacts.isEmpty) {
        throw CodePushNotFoundException(
          message:
              '''No artifact found for architecture $arch in release $releaseId''',
        );
      }
      fetchReleaseArtifactProgress.complete();
      return artifacts.first;
    } on CodePushNotFoundException {
      fetchReleaseArtifactProgress.complete();
      return null;
    } catch (error) {
      _handleErrorAndExit(error, progress: fetchReleaseArtifactProgress);
    }
  }

  /// Uploads android release artifacts for a specific app/release combination.
  Future<void> createAndroidReleaseArtifacts({
    required String appId,
    required int releaseId,
    required ReleasePlatform platform,
    required String projectRoot,
    required String aabPath,
    required Iterable<Arch> architectures,
    String? flavor,
  }) async {
    final createArtifactProgress = logger.progress('Uploading artifacts');
    final archsDir = await ArtifactManager.androidArchsDirectoryFromAab(
      projectRoot: Directory(projectRoot),
      flavor: flavor,
      aab: File(aabPath),
    );

    if (archsDir == null) {
      _handleErrorAndExit(
        Exception('Cannot find patch build artifacts.'),
        progress: createArtifactProgress,
        message: '''
Cannot find release build artifacts.

Please run `flutterpatch cache clean` and try again. If the issue persists, please
file a bug report at https://github.com/josercc/shorebird/issues/new.

Looked in:
  - the libapp.so entries inside the built .aab
  - build/app/intermediates/stripped_native_libs/{variant}/strip{Variant}ReleaseDebugSymbols/out/lib
  - build/app/intermediates/stripped_native_libs/{variant}/out/lib''',
      );
    }

    // Track which arch paths AGP didn't produce, so we can surface them at
    // the end if zero archs uploaded. AGP omits an arch directory whenever
    // the project filters it out via `ndk.abiFilters`, `splits.abi`, or
    // `jniLibs.excludes`. Iterating only over present files lets a filtered
    // release succeed instead of crashing on the first missing arch
    // (https://github.com/shorebirdtech/shorebird/issues/3388).
    final missingArchPaths = <String>[];
    var uploadedArchCount = 0;
    for (final arch in architectures) {
      final artifactPath = p.join(
        archsDir.path,
        arch.androidBuildPath,
        'libapp.so',
      );
      final artifact = File(artifactPath);
      if (!artifact.existsSync()) {
        logger.detail(
          'Skipping ${arch.arch}: no libapp.so at $artifactPath. '
          'This is expected if the project filters this ABI via '
          'ndk.abiFilters, splits.abi, or jniLibs.excludes.',
        );
        missingArchPaths.add(artifactPath);
        continue;
      }
      final hash = sha256.convert(await artifact.readAsBytes()).toString();
      logger.detail('Uploading artifact for $artifactPath');

      try {
        await codePushClient.createReleaseArtifact(
          appId: appId,
          releaseId: releaseId,
          artifactPath: artifact.path,
          arch: arch.arch,
          platform: platform,
          hash: hash,
          canSideload: false,
          podfileLockHash: null,
        );
        uploadedArchCount++;
      } on CodePushConflictException catch (_) {
        uploadedArchCount++;
        // Newlines are due to how logger.info interacts with logger.progress.
        logger.info('''

${arch.arch} artifact already exists, continuing...''');
      } catch (error) {
        _handleErrorAndExit(
          error,
          progress: createArtifactProgress,
          message: 'Error uploading ${artifact.path}: $error',
        );
      }
    }

    if (uploadedArchCount == 0) {
      _handleErrorAndExit(
        Exception('No architecture artifacts found to upload.'),
        progress: createArtifactProgress,
        message:
            '''
No architecture artifacts found to upload.

FlutterPatch looked for libapp.so under ${archsDir.path} but every requested
architecture was missing:
${missingArchPaths.map((p) => '  - $p').join('\n')}

This usually means your project's ndk.abiFilters / splits.abi / jniLibs.excludes
configuration excludes every architecture FlutterPatch was asked to build. Either
relax those filters or pass `--target-platform=<archs>` to restrict FlutterPatch
to the architectures your project actually builds.''',
      );
    }

    try {
      logger.detail('Uploading artifact for $aabPath');
      await codePushClient.createReleaseArtifact(
        appId: appId,
        releaseId: releaseId,
        artifactPath: aabPath,
        arch: 'aab',
        platform: platform,
        hash: sha256.convert(await File(aabPath).readAsBytes()).toString(),
        canSideload: true,
        podfileLockHash: null,
      );
    } on CodePushConflictException catch (_) {
      // Newlines are due to how logger.info interacts with logger.progress.
      logger.info('''

aab artifact already exists, continuing...''');
    } catch (error) {
      _handleErrorAndExit(
        error,
        progress: createArtifactProgress,
        message: 'Error uploading $aabPath: $error',
      );
    }

    createArtifactProgress.complete();
  }

  /// Uploads windows release artifacts for a specific app/release combination.
  Future<void> createWindowsReleaseArtifacts({
    required String appId,
    required int releaseId,
    required String projectRoot,
    required String releaseZipPath,
  }) async {
    final createArtifactProgress = logger.progress('Uploading artifacts');

    try {
      // logger.detail('Uploading artifact for $aabPath');
      await codePushClient.createReleaseArtifact(
        appId: appId,
        releaseId: releaseId,
        artifactPath: releaseZipPath,
        arch: primaryWindowsReleaseArtifactArch,
        platform: ReleasePlatform.windows,
        hash: sha256
            .convert(await File(releaseZipPath).readAsBytes())
            .toString(),
        canSideload: true,
        podfileLockHash: null,
      );
    } on CodePushConflictException catch (_) {
      // Newlines are due to how logger.info interacts with logger.progress.
      logger.info('''

Windows release (exe) artifact already exists, continuing...''');
    } catch (error) {
      _handleErrorAndExit(
        error,
        progress: createArtifactProgress,
        message: 'Error uploading: $error',
      );
    }
    createArtifactProgress.complete();
  }

  /// Uploads android archive release artifacts for a specific app/release combination.
  Future<void> createAndroidArchiveReleaseArtifacts({
    required String appId,
    required int releaseId,
    required ReleasePlatform platform,
    required String aarPath,
    required String extractedAarDir,
    required Iterable<Arch> architectures,
  }) async {
    final createArtifactProgress = logger.progress('Uploading artifacts');

    for (final arch in architectures) {
      final artifactPath = p.join(
        extractedAarDir,
        'jni',
        arch.androidBuildPath,
        'libapp.so',
      );
      final artifact = File(artifactPath);
      final hash = sha256.convert(await artifact.readAsBytes()).toString();
      logger.detail('Uploading artifact for $artifactPath');

      try {
        await codePushClient.createReleaseArtifact(
          appId: appId,
          releaseId: releaseId,
          artifactPath: artifact.path,
          arch: arch.arch,
          platform: platform,
          hash: hash,
          canSideload: false,
          podfileLockHash: null,
        );
      } on CodePushConflictException catch (_) {
        // Newlines are due to how logger.info interacts with logger.progress.
        logger.info('''

${arch.arch} artifact already exists, continuing...''');
      } catch (error) {
        _handleErrorAndExit(
          error,
          progress: createArtifactProgress,
          message: 'Error uploading ${artifact.path}: $error',
        );
      }
    }

    try {
      logger.detail('Uploading artifact for $aarPath');
      await codePushClient.createReleaseArtifact(
        appId: appId,
        releaseId: releaseId,
        artifactPath: aarPath,
        arch: 'aar',
        platform: platform,
        hash: sha256.convert(await File(aarPath).readAsBytes()).toString(),
        canSideload: false,
        podfileLockHash: null,
      );
    } on CodePushConflictException catch (_) {
      // Newlines are due to how logger.info interacts with logger.progress.
      logger.info('''

aar artifact already exists, continuing...''');
    } catch (error) {
      _handleErrorAndExit(
        error,
        progress: createArtifactProgress,
        message: 'Error uploading $aarPath: $error',
      );
    }

    createArtifactProgress.complete();
  }

  /// Removes all .dylib files from the given .xcarchive to reduce the size of
  /// the uploaded artifact.
  Future<Directory> _thinXcarchive({required String xcarchivePath}) async {
    final xcarchiveDirectoryName = p.basename(xcarchivePath);
    final tempDir = Directory.systemTemp.createTempSync();
    final thinnedArchiveDirectory = Directory(
      p.join(tempDir.path, xcarchiveDirectoryName),
    );
    await io.copyPath(xcarchivePath, thinnedArchiveDirectory.path);
    thinnedArchiveDirectory
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => p.extension(file.path) == '.dylib')
        .forEach((file) => file.deleteSync());
    return thinnedArchiveDirectory;
  }

  /// Zips and uploads a Linux release bundle.
  Future<void> createLinuxReleaseArtifacts({
    required String appId,
    required int releaseId,
    required Directory bundle,
  }) async {
    final createArtifactProgress = logger.progress('Uploading artifacts');
    final zippedBundle = await Directory(bundle.path).zipToTempFile();
    try {
      await codePushClient.createReleaseArtifact(
        appId: appId,
        releaseId: releaseId,
        artifactPath: zippedBundle.path,
        arch: primaryLinuxReleaseArtifactArch,
        platform: ReleasePlatform.linux,
        hash: sha256.convert(await zippedBundle.readAsBytes()).toString(),
        canSideload: true,
        podfileLockHash: null,
      );
    } catch (error) {
      _handleErrorAndExit(
        error,
        progress: createArtifactProgress,
        message: 'Error uploading bundle: $error',
      );
    }

    createArtifactProgress.complete();
  }

  /// Registers and uploads macOS release artifacts to the Shorebird server.
  Future<void> createMacosReleaseArtifacts({
    required String appId,
    required int releaseId,
    required String appPath,
    required bool isCodesigned,
    required String? podfileLockHash,
  }) async {
    final createArtifactProgress = logger.progress('Uploading artifacts');
    final tempDir = await Directory.systemTemp.createTemp();
    final zippedApp = File(p.join(tempDir.path, '${p.basename(appPath)}.zip'));
    await ditto.archive(source: appPath, destination: zippedApp.path);

    try {
      await codePushClient.createReleaseArtifact(
        appId: appId,
        releaseId: releaseId,
        artifactPath: zippedApp.path,
        arch: 'app',
        platform: ReleasePlatform.macos,
        hash: sha256.convert(await zippedApp.readAsBytes()).toString(),
        canSideload: true,
        podfileLockHash: podfileLockHash,
      );
    } catch (error) {
      _handleErrorAndExit(
        error,
        progress: createArtifactProgress,
        message: 'Error uploading app: $error',
      );
    }

    createArtifactProgress.complete();
  }

  /// Uploads a release .xcarchive, .app, and supplementary files to the
  /// Shorebird server.
  Future<void> createIosReleaseArtifacts({
    required String appId,
    required int releaseId,
    required String xcarchivePath,
    required String runnerPath,
    required bool isCodesigned,
    required String? podfileLockHash,
  }) async {
    final createArtifactProgress = logger.progress('Uploading artifacts');
    final thinnedArchiveDirectory = await _thinXcarchive(
      xcarchivePath: xcarchivePath,
    );
    final zippedArchive = await thinnedArchiveDirectory.zipToTempFile();
    try {
      await codePushClient.createReleaseArtifact(
        appId: appId,
        releaseId: releaseId,
        artifactPath: zippedArchive.path,
        arch: 'xcarchive',
        platform: ReleasePlatform.ios,
        hash: sha256.convert(await zippedArchive.readAsBytes()).toString(),
        canSideload: false,
        podfileLockHash: podfileLockHash,
      );
    } catch (error) {
      _handleErrorAndExit(
        error,
        progress: createArtifactProgress,
        message: 'Error uploading xcarchive: $error',
      );
    }

    final zippedRunner = await Directory(runnerPath).zipToTempFile();
    try {
      logger.detail('[archive] zipped runner.app to ${zippedRunner.path}');
      await codePushClient.createReleaseArtifact(
        appId: appId,
        releaseId: releaseId,
        artifactPath: zippedRunner.path,
        arch: 'runner',
        platform: ReleasePlatform.ios,
        hash: sha256.convert(await zippedRunner.readAsBytes()).toString(),
        canSideload: isCodesigned,
        podfileLockHash: podfileLockHash,
      );
    } catch (error) {
      _handleErrorAndExit(
        error,
        progress: createArtifactProgress,
        message: 'Error uploading runner.app: $error',
      );
    }

    createArtifactProgress.complete();
  }

  /// Returns all release artifacts for the given [appId], [releaseId], and
  /// [platform], regardless of architecture.
  Future<List<ReleaseArtifact>> getAllReleaseArtifacts({
    required String appId,
    required int releaseId,
    required ReleasePlatform platform,
  }) async {
    final fetchReleaseArtifactProgress = logger.progress(
      'Fetching release artifacts',
    );
    try {
      final artifacts = await codePushClient.getReleaseArtifacts(
        appId: appId,
        releaseId: releaseId,
        platform: platform,
      );
      fetchReleaseArtifactProgress.complete();
      return artifacts;
    } catch (error) {
      _handleErrorAndExit(error, progress: fetchReleaseArtifactProgress);
    }
  }

  /// Downloads every artifact from [sourceReleaseId] and re-uploads them to
  /// [targetReleaseId] for the same [platform].
  ///
  /// Used by `--from-release` to register a new host-app version without
  /// rebuilding Flutter when the Dart/Flutter code has not changed.
  ///
  /// When [artifactHash] is set, prefers the full package patch artifact
  /// matching that hash (patched aar / xcframework) instead of the source
  /// release binaries. Falls back to [sourcePatchNumber] under
  /// [sourceReleaseVersion], then to source release only when
  /// [requirePackageArtifact] is false.
  Future<void> cloneReleaseArtifacts({
    required String appId,
    required int sourceReleaseId,
    required int targetReleaseId,
    required ReleasePlatform platform,
    String? artifactHash,
    int? sourcePatchNumber,
    String? sourceReleaseVersion,
    bool requirePackageArtifact = false,
  }) async {
    final hash = artifactHash?.trim() ?? '';
    final wantsPackage = hash.isNotEmpty || sourcePatchNumber != null;
    if (wantsPackage) {
      final cloned = await _cloneReleaseArtifactsFromPackagePatch(
        appId: appId,
        targetReleaseId: targetReleaseId,
        platform: platform,
        artifactHash: hash.isEmpty ? null : hash,
        sourcePatchNumber: sourcePatchNumber,
        sourceReleaseVersion: sourceReleaseVersion,
      );
      if (cloned) return;
      if (requirePackageArtifact) {
        logger.err(
          'No full package patch artifact found'
          '${hash.isNotEmpty ? ' for hash $hash' : ''}'
          '${sourcePatchNumber != null ? ' (patch #$sourcePatchNumber)' : ''}.\n'
          'Re-run flutterpatch patch so the patched aar/xcframework is uploaded, '
          'then retry --from-release --artifact-hash / --source-patch-number.',
        );
        throw ProcessExit(ExitCode.software.code);
      }
      logger.warn(
        'No full package patch found; '
        'falling back to cloning source release artifacts.',
      );
    }

    final sourceArtifacts = await getAllReleaseArtifacts(
      appId: appId,
      releaseId: sourceReleaseId,
      platform: platform,
    );

    if (sourceArtifacts.isEmpty) {
      logger.err(
        '''No artifacts found on the source release for platform ${platform.name}.''',
      );
      throw ProcessExit(ExitCode.software.code);
    }

    final cloneProgress = logger.progress(
      'Cloning ${sourceArtifacts.length} artifact(s)',
    );
    for (final sourceArtifact in sourceArtifacts) {
      try {
        final downloaded = await artifactManager.downloadFile(
          Uri.parse(sourceArtifact.url),
        );
        final artifactHashValue =
            sha256.convert(await downloaded.readAsBytes()).toString();
        logger.detail(
          'Uploading cloned ${sourceArtifact.arch} artifact '
          '(hash=$artifactHashValue)',
        );
        await codePushClient.createReleaseArtifact(
          appId: appId,
          releaseId: targetReleaseId,
          artifactPath: downloaded.path,
          arch: sourceArtifact.arch,
          platform: platform,
          hash: artifactHashValue,
          canSideload: sourceArtifact.canSideload,
          podfileLockHash: sourceArtifact.podfileLockHash,
        );
      } on CodePushConflictException catch (_) {
        logger.info('''

${sourceArtifact.arch} artifact already exists, continuing...''');
      } catch (error) {
        _handleErrorAndExit(
          error,
          progress: cloneProgress,
          message: 'Error cloning ${sourceArtifact.arch} artifact: $error',
        );
      }
    }
    cloneProgress.complete();
  }

  /// Promotes a patched full-package artifact (and siblings) into [targetReleaseId].
  ///
  /// Returns true when a matching package patch was found and cloned.
  Future<bool> _cloneReleaseArtifactsFromPackagePatch({
    required String appId,
    required int targetReleaseId,
    required ReleasePlatform platform,
    String? artifactHash,
    int? sourcePatchNumber,
    String? sourceReleaseVersion,
  }) async {
    Map<String, dynamic>? package;
    var related = <Map<String, dynamic>>[];

    final hash = artifactHash?.trim() ?? '';
    if (hash.isNotEmpty) {
      final lookup = await codePushClient.lookupBaselinesByArtifactHash(
        artifactHash: hash,
        appId: appId,
        platform: platform.name,
      );
      package = lookup?['package'] as Map<String, dynamic>?;
      final relatedRaw = lookup?['related_packages'];
      if (relatedRaw is List) {
        for (final row in relatedRaw) {
          if (row is Map) {
            related.add(Map<String, dynamic>.from(row));
          }
        }
      }
    }

    if (package == null &&
        sourcePatchNumber != null &&
        sourceReleaseVersion != null &&
        sourceReleaseVersion.isNotEmpty) {
      final patches = await codePushClient.getPatchesByReleaseVersion(
        appId: appId,
        releaseVersion: sourceReleaseVersion,
        platform: platform.name,
      );
      final packageArches = {
        'xcframework',
        'aar',
        'ios_framework_supplement',
        'aar_supplement',
      };
      related = patches
          .where(
            (p) =>
                (p['number'] as num?)?.toInt() == sourcePatchNumber &&
                packageArches.contains('${p['arch']}') &&
                p['rolled_back'] != true &&
                p['rolled_back'] != 1,
          )
          .map((p) => Map<String, dynamic>.from(p))
          .toList();
      for (final row in related) {
        final arch = '${row['arch']}';
        if (arch == 'xcframework' || arch == 'aar') {
          package = row;
          break;
        }
      }
      package ??= related.isEmpty ? null : related.first;
    }

    if (package == null) return false;
    if (related.isEmpty) {
      related = [package];
    }

    final progress = logger.progress(
      'Cloning patched package artifact(s)',
    );
    try {
      for (final row in related) {
        final arch = '${row['arch'] ?? ''}'.trim();
        final path = '${row['artifact_path'] ?? ''}'.trim();
        if (arch.isEmpty || path.isEmpty) continue;
        final downloaded = await codePushClient.downloadAdminArtifact(path);
        final fileHash = sha256.convert(await downloaded.readAsBytes()).toString();
        logger.detail('Uploading package $arch (hash=$fileHash)');
        try {
          await codePushClient.createReleaseArtifact(
            appId: appId,
            releaseId: targetReleaseId,
            artifactPath: downloaded.path,
            arch: arch,
            platform: platform,
            hash: fileHash,
            canSideload: false,
            podfileLockHash: null,
          );
        } on CodePushConflictException catch (_) {
          logger.info('''

$arch artifact already exists, continuing...''');
        }

        if (arch == 'aar') {
          await _uploadAarArchArtifactsFromPackage(
            appId: appId,
            releaseId: targetReleaseId,
            platform: platform,
            aarFile: downloaded,
          );
        }
      }
      progress.complete(
        'Cloned patched package from patch '
        '#${package['number']} (${package['arch']})',
      );
      return true;
    } catch (error) {
      _handleErrorAndExit(
        error,
        progress: progress,
        message: 'Error cloning patched package artifacts: $error',
      );
    }
  }

  /// Extracts per-arch `libapp.so` from a patched aar and registers them as
  /// release artifacts (needed by subsequent `flutterpatch patch --aar`).
  Future<void> _uploadAarArchArtifactsFromPackage({
    required String appId,
    required int releaseId,
    required ReleasePlatform platform,
    required File aarFile,
  }) async {
    final zipPath = p.join(
      Directory.systemTemp.createTempSync().path,
      'patched.aar.zip',
    );
    aarFile.copySync(zipPath);
    final extracted = Directory.systemTemp.createTempSync();
    await artifactManager.extractZip(
      zipFile: File(zipPath),
      outputDirectory: extracted,
    );

    for (final arch in AndroidArch.availableAndroidArchs) {
      final soPath = p.join(
        extracted.path,
        'jni',
        arch.androidBuildPath,
        'libapp.so',
      );
      final soFile = File(soPath);
      if (!soFile.existsSync()) {
        logger.detail('Patched aar missing $soPath, skipping');
        continue;
      }
      final hash = sha256.convert(await soFile.readAsBytes()).toString();
      try {
        await codePushClient.createReleaseArtifact(
          appId: appId,
          releaseId: releaseId,
          artifactPath: soFile.path,
          arch: arch.arch,
          platform: platform,
          hash: hash,
          canSideload: false,
          podfileLockHash: null,
        );
      } on CodePushConflictException catch (_) {
        logger.info('''

${arch.arch} artifact already exists, continuing...''');
      }
    }
  }

  /// Copies the latest active OTA snapshot and resource config from
  /// [sourceReleaseVersion] onto [targetReleaseVersion] for [platform].
  ///
  /// Used by `--from-release` so host-app version bumps keep the same OTA
  /// baselines as the Flutter artifacts they reuse. Content-addressed asset
  /// blobs are shared by hash and do not need re-uploading.
  ///
  /// When [artifactHash] or [sourcePatchNumber] is set, resolution and upload
  /// hard-fail on mismatch (no soft-warn). Legacy calls without those args
  /// still soft-fail so a missing OTA baseline does not undo artifact clone.
  // flutterpatch: ownership=FORK — from meta_ota
  Future<void> cloneReleaseBaselines({
    required String appId,
    required String sourceReleaseVersion,
    required String targetReleaseVersion,
    required String platform,
    String? artifactHash,
    int? sourcePatchNumber,
  }) async {
    final strict = (artifactHash != null && artifactHash.trim().isNotEmpty) ||
        sourcePatchNumber != null;
    final progress = logger.progress('Cloning OTA baselines');
    try {
      var clonedSnapshot = false;
      var clonedResources = false;

      final snapshots = await codePushClient.listOtaSnapshots(
        appId: appId,
        releaseVersion: sourceReleaseVersion,
        platform: platform,
        artifactHash: artifactHash,
      );
      final activeSnapshot = _resolveSourceBaseline(
        snapshots,
        artifactHash: artifactHash,
        sourcePatchNumber: sourcePatchNumber,
        kind: 'snapshot',
      );
      if (activeSnapshot != null) {
        final id = activeSnapshot['id'] as String;
        final bytes = await codePushClient.getOtaSnapshotContent(id);
        _assertClonedBaseline(
          meta: activeSnapshot,
          bytes: bytes,
          expectedVersion: sourceReleaseVersion,
          expectedArtifactHash: artifactHash,
          expectedPatchNumber: sourcePatchNumber,
          kind: 'snapshot',
        );
        final decoded = jsonDecode(utf8.decode(bytes));
        final fileCount = decoded is Map && decoded['files'] is List
            ? (decoded['files'] as List).length
            : (activeSnapshot['file_count'] as num?)?.toInt();
        final channel =
            activeSnapshot['channel'] as String? ?? 'stable';
        final sourceOrigin = '${activeSnapshot['origin'] ?? 'release'}';
        final sourcePatch =
            (activeSnapshot['patch_number'] as num?)?.toInt();
        final notes = sourceOrigin == 'patch' && sourcePatch != null
            ? 'Cloned from $sourceReleaseVersion (patch #$sourcePatch)'
            : 'Cloned from $sourceReleaseVersion';
        await codePushClient.uploadOtaSnapshot(
          appId: appId,
          releaseVersion: targetReleaseVersion,
          contentBytes: bytes,
          platform: platform,
          channel: channel,
          notes: notes,
          fileCount: fileCount,
          origin: 'release',
          artifactHash: artifactHash ??
              activeSnapshot['artifact_hash'] as String?,
        );
        clonedSnapshot = true;
        logger.detail(
          'Cloned OTA snapshot #${activeSnapshot['number']} '
          '→ $targetReleaseVersion',
        );
      }

      final resources = await codePushClient.listResourceSnapshots(
        appId: appId,
        releaseVersion: sourceReleaseVersion,
        platform: platform,
        artifactHash: artifactHash,
      );
      final activeResource = _resolveSourceBaseline(
        resources,
        artifactHash: artifactHash,
        sourcePatchNumber: sourcePatchNumber,
        kind: 'resource',
      );
      if (activeResource != null) {
        final id = activeResource['id'] as String;
        final sourceBytes = await codePushClient.getResourceSnapshotContent(
          id,
        );
        _assertClonedBaseline(
          meta: activeResource,
          bytes: sourceBytes,
          expectedVersion: sourceReleaseVersion,
          expectedArtifactHash: artifactHash,
          expectedPatchNumber: sourcePatchNumber,
          kind: 'resource',
        );
        final contentBytes = _rewriteResourceReleaseVersion(
          sourceBytes,
          targetReleaseVersion,
        );
        final decoded = jsonDecode(utf8.decode(contentBytes));
        final resourceCount = decoded is Map && decoded['resources'] is List
            ? (decoded['resources'] as List).length
            : (activeResource['resource_count'] as num?)?.toInt();
        final channel =
            activeResource['channel'] as String? ?? 'stable';
        final sourceOrigin = '${activeResource['origin'] ?? 'release'}';
        final sourcePatch =
            (activeResource['patch_number'] as num?)?.toInt();
        final notes = sourceOrigin == 'patch' && sourcePatch != null
            ? 'Cloned from $sourceReleaseVersion (patch #$sourcePatch)'
            : 'Cloned from $sourceReleaseVersion';
        await codePushClient.uploadResourceSnapshot(
          appId: appId,
          releaseVersion: targetReleaseVersion,
          contentBytes: contentBytes,
          platform: platform,
          channel: channel,
          notes: notes,
          resourceCount: resourceCount,
          origin: 'release',
          artifactHash: artifactHash ??
              activeResource['artifact_hash'] as String?,
        );
        clonedResources = true;
        logger.detail(
          'Cloned resource config #${activeResource['number']} '
          '→ $targetReleaseVersion',
        );
      }

      if (!clonedSnapshot && !clonedResources) {
        if (strict) {
          progress.fail(
            'No OTA baselines matched artifact_hash/patch for '
            '$sourceReleaseVersion',
          );
          throw StateError(
            'No matching OTA baselines for clone from $sourceReleaseVersion',
          );
        }
        progress.complete(
          'No OTA baselines on source release $sourceReleaseVersion',
        );
        logger.info(
          '''
Source release has no published OTA snapshot or resource config.
After cloning you can still upload baselines with:
  flutterpatch upload-snapshot --version $targetReleaseVersion --platform $platform
  flutterpatch upload-resources --version $targetReleaseVersion --platform $platform''',
        );
        return;
      }

      final parts = <String>[
        if (clonedSnapshot) 'snapshot',
        if (clonedResources) 'resource config',
      ];
      progress.complete('Cloned OTA ${parts.join(' + ')}');
    } catch (error) {
      progress.fail('Failed to clone OTA baselines: $error');
      if (strict) {
        throw ProcessExit(ExitCode.software.code);
      }
      logger.info(
        '''
Release artifacts were cloned; re-run baselines manually:
  flutterpatch upload-snapshot --version $targetReleaseVersion --platform $platform
  flutterpatch upload-resources --version $targetReleaseVersion --platform $platform''',
      );
    }
  }

  /// Newest non-rolled-back baseline row matching optional provenance filters.
  Map<String, dynamic>? _resolveSourceBaseline(
    List<Map<String, dynamic>> rows, {
    String? artifactHash,
    int? sourcePatchNumber,
    required String kind,
  }) {
    final expectedHash = artifactHash?.trim().toLowerCase();
    final filtered = rows.where((e) {
      if (e['rolled_back'] == true || e['rolled_back'] == 1) return false;
      if (expectedHash != null && expectedHash.isNotEmpty) {
        final actual = '${e['artifact_hash'] ?? ''}'.trim().toLowerCase();
        if (actual != expectedHash) return false;
      }
      if (sourcePatchNumber != null) {
        final origin = '${e['origin'] ?? ''}'.trim().toLowerCase();
        final patch = (e['patch_number'] as num?)?.toInt();
        if (origin != 'patch' || patch != sourcePatchNumber) return false;
      }
      return true;
    }).toList()
      ..sort(
        (a, b) => ((b['number'] as num?)?.toInt() ?? 0).compareTo(
          (a['number'] as num?)?.toInt() ?? 0,
        ),
      );
    if (filtered.isEmpty &&
        (expectedHash != null && expectedHash.isNotEmpty ||
            sourcePatchNumber != null)) {
      throw StateError(
        'No $kind baseline matched artifact_hash='
        '${artifactHash ?? "(any)"} patch=${sourcePatchNumber ?? "(any)"}',
      );
    }
    return filtered.firstOrNull;
  }

  void _assertClonedBaseline({
    required Map<String, dynamic> meta,
    required List<int> bytes,
    required String expectedVersion,
    required String? expectedArtifactHash,
    required int? expectedPatchNumber,
    required String kind,
  }) {
    final metaVersion = '${meta['release_version'] ?? ''}';
    if (metaVersion.isNotEmpty && metaVersion != expectedVersion) {
      throw StateError(
        'baseline $kind release_version=$metaVersion, '
        'expected $expectedVersion',
      );
    }
    final contentHash = '${meta['hash'] ?? ''}'.trim().toLowerCase();
    if (contentHash.isNotEmpty) {
      final actual = sha256.convert(bytes).toString();
      if (actual != contentHash) {
        throw StateError(
          'baseline $kind content hash mismatch: got $actual, '
          'expected $contentHash',
        );
      }
    }
    final expected = expectedArtifactHash?.trim().toLowerCase();
    if (expected != null && expected.isNotEmpty) {
      final actual = '${meta['artifact_hash'] ?? ''}'.trim().toLowerCase();
      if (actual != expected) {
        throw StateError(
          'baseline $kind artifact_hash mismatch: got $actual, '
          'expected $expected',
        );
      }
    }
    if (expectedPatchNumber != null) {
      final origin = '${meta['origin'] ?? ''}'.trim().toLowerCase();
      final patch = (meta['patch_number'] as num?)?.toInt();
      if (origin != 'patch' || patch != expectedPatchNumber) {
        throw StateError(
          'baseline $kind expected patch #$expectedPatchNumber, '
          'got origin=$origin patch=$patch',
        );
      }
    } else if (expectedArtifactHash != null &&
        expectedArtifactHash.trim().isNotEmpty) {
      // By-hash release promote: require origin=release (or legacy unset).
      final origin = '${meta['origin'] ?? 'release'}'.trim().toLowerCase();
      if (origin != 'release') {
        throw StateError(
          'baseline $kind artifact_hash matched but origin=$origin '
          '(expected release); pass --source-patch-number for patched '
          'baselines',
        );
      }
    }
  }

  /// Rewrites `release_version` inside a resource snapshot JSON payload.
  List<int> _rewriteResourceReleaseVersion(
    List<int> bytes,
    String releaseVersion,
  ) {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) return bytes;
    final map = Map<String, dynamic>.from(decoded);
    if (map['release_version'] == releaseVersion) return bytes;
    map['release_version'] = releaseVersion;
    return utf8.encode(
      '${const JsonEncoder.withIndent('  ').convert(map)}\n',
    );
  }

  /// Zips and uploads a release xcframework and supplementary files to the
  /// Shorebird server.
  Future<void> createIosFrameworkReleaseArtifacts({
    required String appId,
    required int releaseId,
    required String appFrameworkPath,
  }) async {
    final createArtifactProgress = logger.progress('Uploading artifacts');
    final appFrameworkDirectory = Directory(appFrameworkPath);
    final zippedAppFrameworkFile = await appFrameworkDirectory.zipToTempFile();
    try {
      await codePushClient.createReleaseArtifact(
        appId: appId,
        releaseId: releaseId,
        artifactPath: zippedAppFrameworkFile.path,
        arch: 'xcframework',
        platform: ReleasePlatform.ios,
        hash: sha256
            .convert(await zippedAppFrameworkFile.readAsBytes())
            .toString(),
        canSideload: false,
        podfileLockHash: null,
      );
    } catch (error) {
      _handleErrorAndExit(
        error,
        progress: createArtifactProgress,
        message: 'Error uploading xcframework: $error',
      );
    }

    createArtifactProgress.complete();
  }

  /// Zips and uploads a supplement directory as a release artifact.
  Future<void> createSupplementReleaseArtifact({
    required String appId,
    required int releaseId,
    required ReleasePlatform platform,
    required String supplementDirectoryPath,
    required String arch,
  }) async {
    final createSupplementProgress = logger.progress(
      'Uploading supplement artifacts',
    );
    final zippedSupplement = await Directory(
      supplementDirectoryPath,
    ).zipToTempFile(name: arch);
    try {
      await codePushClient.createReleaseArtifact(
        appId: appId,
        releaseId: releaseId,
        artifactPath: zippedSupplement.path,
        arch: arch,
        platform: platform,
        hash: sha256.convert(await zippedSupplement.readAsBytes()).toString(),
        // Supplements are auxiliary snapshot metadata used during patching and
        // can't produce a working app on their own, so sideloading isn't
        // applicable.
        canSideload: false,
        // Supplement artifacts contain only Dart snapshot metadata (e.g. class
        // tables, dispatch tables) and have no dependency on native pods, so
        // the podfile lock hash is not applicable here.
        podfileLockHash: null,
      );
    } catch (error) {
      _handleErrorAndExit(
        error,
        progress: createSupplementProgress,
        message: 'Error uploading supplement artifacts: $error',
      );
    }
    createSupplementProgress.complete();
  }

  /// Creates a patch for the given [appId], [releaseId], and [metadata].
  @visibleForTesting
  Future<Patch> createPatch({
    required String appId,
    required int releaseId,
    required Json metadata,
    List<Map<String, dynamic>>? changedResources,
    int? resourceNumber,
    bool force = false,
    bool? whitelistEnabled,
    List<String>? uniqueIds,
  }) async {
    final createPatchProgress = logger.progress('Creating patch');
    try {
      final patch = await codePushClient.createPatch(
        appId: appId,
        releaseId: releaseId,
        metadata: metadata,
        changedResources: changedResources,
        resourceNumber: resourceNumber,
        force: force,
        whitelistEnabled: whitelistEnabled,
        uniqueIds: uniqueIds,
      );
      createPatchProgress.complete();
      return patch;
    } catch (error) {
      _handleErrorAndExit(error, progress: createPatchProgress);
    }
  }

  /// Uploads patch artifacts for a specific app/patch combination.
  @visibleForTesting
  Future<void> createPatchArtifacts({
    required String appId,
    required Patch patch,
    required ReleasePlatform platform,
    required Map<Arch, PatchArtifactBundle> patchArtifactBundles,
  }) async {
    final createArtifactProgress = logger.progress('Uploading artifacts');
    for (final artifact in patchArtifactBundles.values) {
      try {
        await codePushClient.createPatchArtifact(
          appId: appId,
          patchId: patch.id,
          artifactPath: artifact.path,
          arch: artifact.arch,
          platform: platform,
          hash: artifact.hash,
          hashSignature: artifact.hashSignature,
          podfileLockHash: artifact.podfileLockHash,
        );
      } catch (error) {
        _handleErrorAndExit(error, progress: createArtifactProgress);
      }
    }
    createArtifactProgress.complete();
  }

  /// Promotes a patch to a specific [channel].
  Future<void> promotePatch({
    required String appId,
    required int patchId,
    required Channel channel,
  }) async {
    final promotePatchProgress = logger.progress(
      'Promoting patch to ${channel.name}',
    );
    try {
      await codePushClient.promotePatch(
        appId: appId,
        patchId: patchId,
        channelId: channel.id,
      );
      promotePatchProgress.complete();
    } catch (error) {
      _handleErrorAndExit(error, progress: promotePatchProgress);
    }
  }

  /// Rolls back the patch identified by [patchId] under [releaseId]. Returns
  /// whether the server changed the patch, which is `false` when it was
  /// already rolled back.
  ///
  /// [patchNumber] is used purely for the human-readable progress message;
  /// pass it through when the caller already has it on hand.
  Future<bool> rollbackPatch({
    required String appId,
    required int releaseId,
    required int patchId,
    int? patchNumber,
  }) async {
    final label = patchNumber != null ? 'patch $patchNumber' : 'patch';
    final progress = logger.progress('Rolling back $label');
    try {
      final changed = await codePushClient.rollbackPatch(
        appId: appId,
        releaseId: releaseId,
        patchId: patchId,
      );
      // A completed spinner would claim the rollback happened, so say so when
      // the server reported there was nothing to change.
      progress.complete(
        changed ? null : 'No change: $label was already rolled back',
      );
      return changed;
    } catch (error) {
      _handleErrorAndExit(error, progress: progress);
    }
  }

  /// Rolls forward (un-rolls-back) the patch identified by [patchId] under
  /// [releaseId], returning it to its active state so the server resends the
  /// same patch artifact to devices on the next patch check. Returns whether
  /// the server changed the patch, which is `false` when it was already
  /// active.
  ///
  /// [patchNumber] is used purely for the human-readable progress message;
  /// pass it through when the caller already has it on hand.
  Future<bool> rollforwardPatch({
    required String appId,
    required int releaseId,
    required int patchId,
    int? patchNumber,
  }) async {
    final label = patchNumber != null ? 'patch $patchNumber' : 'patch';
    final progress = logger.progress('Rolling forward $label');
    try {
      final changed = await codePushClient.rollforwardPatch(
        appId: appId,
        releaseId: releaseId,
        patchId: patchId,
      );
      // A completed spinner would claim the rollforward happened, so say so
      // when the server reported there was nothing to change.
      progress.complete(
        changed ? null : 'No change: $label was already active',
      );
      return changed;
    } catch (error) {
      _handleErrorAndExit(error, progress: progress);
    }
  }

  /// Publishes a patch to the Shorebird server. This consists of creating a
  /// patch, uploading patch artifacts, and promoting the patch to a specific
  /// channel based on the provided [track].
  Future<int> publishPatch({
    required String appId,
    required int releaseId,
    required Json metadata,
    required ReleasePlatform platform,
    required DeploymentTrack track,
    required Map<Arch, PatchArtifactBundle> patchArtifactBundles,
    List<Map<String, dynamic>>? changedResources,
    int? resourceNumber,
    bool force = false,
    bool? whitelistEnabled,
    List<String>? uniqueIds,
  }) async {
    final patch = await createPatch(
      appId: appId,
      releaseId: releaseId,
      metadata: metadata,
      changedResources: changedResources,
      resourceNumber: resourceNumber,
      force: force,
      whitelistEnabled: whitelistEnabled,
      uniqueIds: uniqueIds,
    );

    await createPatchArtifacts(
      appId: appId,
      patch: patch,
      platform: platform,
      patchArtifactBundles: patchArtifactBundles,
    );

    final channel =
        await maybeGetChannel(appId: appId, name: track.channel) ??
        await createChannel(appId: appId, name: track.channel);

    await promotePatch(appId: appId, patchId: patch.id, channel: channel);

    final number = codePushClient.patchNumberFor(patch.id) ?? patch.number;
    logger.success('\n✅ Published Patch $number!');
    return number;
  }

  /// Returns a GCP download link for measuring download speed.
  Future<Uri> getGCPDownloadSpeedTestUrl() {
    return codePushClient.getGCPDownloadSpeedTestUrl();
  }

  /// Returns a GCP upload link for measuring upload speed.
  Future<Uri> getGCPUploadSpeedTestUrl() {
    return codePushClient.getGCPUploadSpeedTestUrl();
  }

  /// Prints an appropriate error message for the given error and exits with
  /// code 70. If [progress] is provided, it will be failed with the given
  /// [message] or [error.toString()] if [message] is null.
  Never _handleErrorAndExit(
    Object error, {
    Progress? progress,
    String? message,
  }) {
    if (error is CodePushUpgradeRequiredException) {
      progress?.fail();
      logger
        ..err('Your version of FlutterPatch is out of date.')
        ..info(
          '''Run ${lightCyan.wrap('flutterpatch upgrade')} to get the latest version.''',
        );
    } else if (progress != null) {
      progress.fail(message ?? '$error');
    }

    throw ProcessExit(ExitCode.software.code);
  }
}
