import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/executables/devicectl/apple_device.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_process.dart';

/// A reference to a [IDeviceSysLog] instance.
final idevicesyslogRef = create(IDeviceSysLog.new);

/// The [IDeviceSysLog] instance available in the current zone.
IDeviceSysLog get idevicesyslog => read(idevicesyslogRef);

/// {@template idevicesyslog}
/// A wrapper around the `idevicesyslog` executable.
/// {@endtemplate}
class IDeviceSysLog {
  /// The location of the libimobiledevice library, which contains
  /// idevicesyslog.
  static Directory get libimobiledeviceDirectory => Directory(
    p.join(
      shorebirdEnv.flutterDirectory.path,
      'bin',
      'cache',
      'artifacts',
      'libimobiledevice',
    ),
  );

  /// The location of the idevicesyslog executable.
  static File get idevicesyslogExecutable =>
      File(p.join(libimobiledeviceDirectory.path, 'idevicesyslog'));

  /// The libraries that idevicesyslog depends on.
  @visibleForTesting
  // Directory names under flutter/bin/cache/artifacts. These must match the
  // on-disk artifact folders shipped by `flutter precache --ios` (note:
  // libusbmuxd / libimobiledeviceglue — not "usbmuxd").
  static const deps = [
    'libimobiledevice',
    'libusbmuxd',
    'libimobiledeviceglue',
    'libplist',
    'openssl',
    'ios-deploy',
  ];

  /// idevicesyslog has Flutter-provided dependencies, so we need to tell the
  /// dynamic linker where to find them.
  String get _dyldPathEntry => deps
      .map(
        (dep) => p.join(
          shorebirdEnv.flutterDirectory.path,
          'bin',
          'cache',
          'artifacts',
          dep,
        ),
      )
      .join(':');

  /// idevicesyslog tails all logs produced by the device (similar to what is
  /// shown in Console.app). This is very noisy and we only want to show logs
  /// that are produced by the app. These log lines are of the form:
  // ignore: unintended_html_in_doc_comment
  ///   Nov 10 14:46:57 Runner(Flutter)[1044] <Notice>: flutter: hello
  static RegExp appLogLineRegex = RegExp(r'\(Flutter\)\[\d+\] <\w+>: (.*)$');

  /// Starts an instance of idevicesyslog for the given device ID. Returns the
  /// exit code of the process.
  ///
  /// stdout and stderr are parsed for lines matching [appLogLineRegex], and
  /// those lines are logged at an info level.
  Future<int> startLogger({required AppleDevice device}) async {
    logger.detail(
      'launching idevicesyslog with DYLD_LIBRARY_PATH=$_dyldPathEntry',
    );
    if (!idevicesyslogExecutable.existsSync()) {
      logger.warn(
        'idevicesyslog not found at ${idevicesyslogExecutable.path}. '
        'Flutter runtime logs will not be available.',
      );
    }

    final loggerProcess = await process.start(
      idevicesyslogExecutable.path,
      [
        '-u',
        device.udid,
        // If the device is not connected via USB, we need to specify the
        // network flag.
        if (!device.isWired) '--network',
      ],
      environment: {'DYLD_LIBRARY_PATH': _dyldPathEntry},
    );

    // Use allowMalformed to handle non-UTF8 bytes in device syslog output.
    const decoder = Utf8Decoder(allowMalformed: true);
    final stdoutDone = loggerProcess.stdout
        .transform<String>(decoder)
        .transform<String>(const LineSplitter())
        .listen(_parseLogLine)
        .asFuture<void>();
    final stderrDone = loggerProcess.stderr
        .transform<String>(decoder)
        .transform<String>(const LineSplitter())
        .listen(_parseLogLine)
        .asFuture<void>();
    final exitCode = await loggerProcess.exitCode;
    // Wait for stream listeners so fast-failing processes (e.g. missing
    // dylibs) still surface their stderr before we reconnect/return.
    await Future.wait<void>([stdoutDone, stderrDone]);
    return exitCode;
  }

  void _parseLogLine(String line) {
    final matches = appLogLineRegex.allMatches(line);
    if (matches.isNotEmpty) {
      logger.info(matches.first.group(1));
      return;
    }

    // Surface loader / connection failures that would otherwise be silent —
    // without these, preview appears "attached" but shows no Flutter logs.
    final lower = line.toLowerCase();
    if (lower.contains('library not loaded') ||
        lower.contains('image not found') ||
        lower.contains('error:') ||
        lower.contains('unable to') ||
        lower.contains('not connected') ||
        lower.startsWith('[connected:')) {
      logger.info(line);
    }
  }
}
