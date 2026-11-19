import 'dart:async';
import 'dart:io';

import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/android_sdk.dart';
import 'package:shorebird_cli/src/shorebird_process.dart';

/// A reference to a [Adb] instance.
final adbRef = create(Adb.new);

/// The [Adb] instance available in the current zone.
Adb get adb => read(adbRef);

/// An Android device/emulator reported by `adb devices -l`.
class AndroidDevice {
  /// Creates an [AndroidDevice].
  const AndroidDevice({required this.id, this.model});

  /// Serial / emulator id (passed to `adb -s`).
  final String id;

  /// Optional model from `adb devices -l` (e.g. `SM_G973U`).
  final String? model;

  /// Human-readable label for prompts.
  String get displayName {
    if (model == null || model!.isEmpty) return id;
    return '$model ($id)';
  }

  @override
  String toString() => displayName;
}

/// A wrapper around the `adb` command.
class Adb {
  Future<ShorebirdProcessResult> _exec(String command) async {
    final adbPath = androidSdk.adbPath;
    if (adbPath == null) throw Exception('Unable to locate adb.');

    return process.run(adbPath, command.split(' '));
  }

  Future<Process> _stream(String command) async {
    final adbPath = androidSdk.adbPath;
    if (adbPath == null) throw Exception('Unable to locate adb.');

    return process.start(adbPath, command.split(' '));
  }

  /// Lists connected Android devices/emulators in the `device` state.
  ///
  /// Runs `adb devices -l` and ignores offline / unauthorized entries.
  Future<List<AndroidDevice>> listDevices() async {
    final result = await _exec('devices -l');
    if (result.exitCode != 0) {
      throw Exception('Unable to list devices: ${result.stderr}');
    }

    final devices = <AndroidDevice>[];
    for (final line in '${result.stdout}'.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('List of devices')) {
        continue;
      }

      // Example:
      // emulator-5554 device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64
      final parts = trimmed.split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      final id = parts[0];
      final state = parts[1];
      if (state != 'device') continue;

      String? model;
      for (final part in parts.skip(2)) {
        if (part.startsWith('model:')) {
          model = part.substring('model:'.length).replaceAll('_', ' ');
          break;
        }
      }
      devices.add(AndroidDevice(id: id, model: model));
    }
    return devices;
  }

  /// Installs the APK at [apkPath] onto the device (replaces existing app).
  Future<void> installApk({required String apkPath, String? deviceId}) async {
    final args = [
      if (deviceId != null) ...['-s', deviceId],
      'install',
      '-r',
      apkPath,
    ];
    final result = await _exec(args.join(' '));
    if (result.exitCode != 0) {
      throw Exception('Unable to install apk: ${result.stderr}');
    }
  }

  /// Clears the app data for the given [package] name.
  Future<void> clearAppData({required String package, String? deviceId}) async {
    final args = [
      if (deviceId != null) ...['-s', deviceId],
      'shell',
      'pm',
      'clear',
      package,
    ];
    final result = await _exec(args.join(' '));
    if (result.exitCode != 0) {
      throw Exception('Unable to clear app data: ${result.stderr}');
    }
  }

  /// Starts the app with the given [package] name.
  Future<void> startApp({required String package, String? deviceId}) async {
    final args = [
      if (deviceId != null) ...['-s', deviceId],
      'shell',
      'monkey',
      // Adjust percentage of "system" key events to 0.
      // This is needed to support Android systems with no hardware keys.
      '--pct-syskeys 0',
      '-p $package',
      '1',
    ];
    final result = await _exec(args.join(' '));
    if (result.exitCode != 0) {
      throw Exception('Unable to start app: ${result.stderr}');
    }
  }

  /// Runs `adb logcat`.
  Future<Process> logcat({String? filter, String? deviceId}) async {
    final args = [
      if (deviceId != null) ...['-s', deviceId],
      'logcat',
      // This arg prevents old logs from being displayed.
      ...['-T', '1'],
      if (filter != null) ...['-s', filter],
    ];
    return _stream(args.join(' '));
  }
}
