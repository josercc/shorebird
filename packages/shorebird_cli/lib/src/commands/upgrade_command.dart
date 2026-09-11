// flutterpatch: ownership=REPLACE
import 'package:mason_logger/mason_logger.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_cli/src/shorebird_command.dart';
import 'package:shorebird_cli/src/shorebird_process.dart';

/// {@template upgrade_command}
/// `flutterpatch upgrade`
///
/// Re-runs the one-click installer with `--force` to install the latest CLI
/// package. Flutter SDK cache is left alone (`--skip-flutter`); shell rc files
/// are not modified (`--skip-path`).
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
        // --skip-flutter: upgrade only replaces the CLI package.
        'curl -fsSL "\$$installUrlEnvVar" | '
            'bash -s -- --force --skip-path --skip-flutter',
      ],
      environment: environment,
    );
  }

  Future<int> _runWindowsInstaller(String installUrl) {
    final environment = Map<String, String>.of(platform.environment)
      ..[installUrlEnvVar] = installUrl;

    // Download to a temp .ps1 then invoke with -Force -SkipPath -SkipFlutter
    // (iex alone cannot pass parameters cleanly).
    const command =
        r'''
$ErrorActionPreference = 'Stop'
$url = $env:FLUTTERPATCH_INSTALL_URL
$tmp = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ('flutterpatch-upgrade-' + [guid]::NewGuid().ToString() + '.ps1'))
try {
  Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $tmp
  & $tmp -Force -SkipPath -SkipFlutter
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
}
