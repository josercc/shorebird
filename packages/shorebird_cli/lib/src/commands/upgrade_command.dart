// flutterpatch: ownership=REPLACE
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_cli/src/shorebird_command.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_process.dart';
import 'package:shorebird_cli/src/shorebird_version.dart';

/// {@template upgrade_command}
/// `flutterpatch upgrade`
///
/// Packaged (website) installs re-run the one-click installer with `--force`.
/// Git checkouts keep the Shorebird-style `git reset` upgrade path.
/// {@endtemplate}
class UpgradeCommand extends ShorebirdCommand {
  /// {@macro upgrade_command}
  UpgradeCommand();

  @override
  String get description => 'Upgrade your copy of FlutterPatch.';

  /// Name of the command.
  static const String commandName = 'upgrade';

  /// Default macOS/Linux installer script (raw from this fork).
  static const String defaultInstallScriptUrl =
      'https://raw.githubusercontent.com/josercc/shorebird/main/scripts/install.sh';

  /// Default Windows installer script (raw from this fork).
  static const String defaultInstallScriptUrlWindows =
      'https://raw.githubusercontent.com/josercc/shorebird/main/scripts/install.ps1';

  /// Env override for the installer script URL.
  static const String installUrlEnvVar = 'FLUTTERPATCH_INSTALL_URL';

  @override
  String get name => commandName;

  @override
  Future<int> run() async {
    if (shorebirdEnv.isGitInstall) {
      return _upgradeGitInstall();
    }
    return _upgradePackagedInstall();
  }

  /// Re-runs [scripts/install.sh] / [scripts/install.ps1] with `--force`
  /// (and `--skip-path` so shell rc files are left alone).
  Future<int> _upgradePackagedInstall() async {
    final installUrl = _resolveInstallScriptUrl();
    logger
      ..info('Upgrading FlutterPatch via installer…')
      ..detail('Installer: $installUrl');

    final int exitCode;
    try {
      if (platform.isWindows) {
        exitCode = await _runWindowsInstaller(installUrl);
      } else {
        exitCode = await _runUnixInstaller(installUrl);
      }
    } on Exception catch (error) {
      logger.err('Upgrade failed: $error');
      return ExitCode.software.code;
    }

    if (exitCode != ExitCode.success.code) {
      logger.err('Upgrade failed (exit code $exitCode).');
      return exitCode;
    }

    logger.info('FlutterPatch upgraded successfully.');
    return ExitCode.success.code;
  }

  String _resolveInstallScriptUrl() {
    final fromEnv = platform.environment[installUrlEnvVar]?.trim();
    if (fromEnv != null && fromEnv.isNotEmpty) {
      return fromEnv;
    }
    return platform.isWindows
        ? defaultInstallScriptUrlWindows
        : defaultInstallScriptUrl;
  }

  Future<int> _runUnixInstaller(String installUrl) {
    // Inherit parent env (PATH, FLUTTERPATCH_ROOT, catalog overrides, …).
    final environment = Map<String, String>.of(platform.environment)
      ..[installUrlEnvVar] = installUrl;

    return process.stream(
      'bash',
      [
        '-c',
        // curl|bash mirrors the documented one-click install UX.
        'curl -fsSL "\$$installUrlEnvVar" | bash -s -- --force --skip-path',
      ],
      environment: environment,
    );
  }

  Future<int> _runWindowsInstaller(String installUrl) {
    final environment = Map<String, String>.of(platform.environment)
      ..[installUrlEnvVar] = installUrl;

    // Download to a temp .ps1 then invoke with -Force -SkipPath (iex alone
    // cannot pass parameters cleanly).
    const command =
        r'''
$ErrorActionPreference = 'Stop'
$url = $env:FLUTTERPATCH_INSTALL_URL
$tmp = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ('flutterpatch-upgrade-' + [guid]::NewGuid().ToString() + '.ps1'))
try {
  Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $tmp
  & $tmp -Force -SkipPath
  exit $LASTEXITCODE
} finally {
  Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}
''';

    return process.stream(
      'powershell',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', command],
      environment: environment,
    );
  }

  /// Original Shorebird git-checkout upgrade (`git fetch` + hard reset).
  Future<int> _upgradeGitInstall() async {
    final updateCheckProgress = logger.progress('Checking for updates');

    late final String currentVersion;
    try {
      currentVersion = await shorebirdVersion.fetchCurrentGitHash();
    } on ProcessException catch (error) {
      updateCheckProgress.fail();
      logger.err('Fetching current version failed: ${error.message}');
      return ExitCode.software.code;
    }

    late final String latestVersion;
    try {
      latestVersion = await shorebirdVersion.fetchLatestGitHash();
    } on ProcessException catch (error) {
      updateCheckProgress.fail();
      logger.err('Checking for updates failed: ${error.message}');
      return ExitCode.software.code;
    }

    updateCheckProgress.complete('Checked for updates');

    if (currentVersion == latestVersion) {
      logger.info('FlutterPatch is already at the latest version.');
      return ExitCode.success.code;
    }

    final updateProgress = logger.progress('Updating');
    try {
      await shorebirdVersion.attemptReset(revision: latestVersion);
    } on ProcessException catch (error) {
      updateProgress.fail();
      logger.err('Updating failed: ${error.message}');
      return ExitCode.software.code;
    }

    updateProgress.complete('Updated successfully.');
    return ExitCode.success.code;
  }
}
