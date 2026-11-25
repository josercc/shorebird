// flutterpatch: ownership=REPLACE — stable machine-bound X-Device-Id + fingerprint
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Optional override for [resolveCliDeviceId] (label only; does not bypass
/// [resolveCliMachineFingerprint]).
const flutterpatchDeviceIdEnvVar = 'FLUTTERPATCH_DEVICE_ID';

/// Optional CI override for [resolveCliMachineFingerprint]. Using the same
/// value on two machines re-enables key sharing — only for ephemeral runners.
const flutterpatchMachineFingerprintEnvVar = 'FLUTTERPATCH_MACHINE_FINGERPRINT';

/// Header name expected by control_api for API-key device binding.
const flutterpatchDeviceIdHeader = 'x-device-id';

/// Header name for live host machine-id hash (hard bind).
const flutterpatchMachineFingerprintHeader = 'x-machine-fingerprint';

String? _cachedCliDeviceId;
String? _cachedCliMachineFingerprint;

/// Clears the process-local cache (tests).
void clearCliDeviceIdCache() {
  _cachedCliDeviceId = null;
  _cachedCliMachineFingerprint = null;
}

/// Resolves a stable device id for `X-Device-Id` on authenticated CLI requests.
///
/// Order:
/// 1. [flutterpatchDeviceIdEnvVar] when non-empty
/// 2. `cli_` + SHA-256 of the host machine-id
/// 3. Persisted `~/.flutterpatch/cli_device_id` (create once if missing)
///
/// Overriding this alone cannot bypass API-key binding; the server also checks
/// [resolveCliMachineFingerprint].
String resolveCliDeviceId({
  Map<String, String>? environment,
  String? Function()? readMachineIdRaw,
  String? homePath,
}) {
  final cached = _cachedCliDeviceId;
  if (cached != null) return cached;

  final env = environment ?? Platform.environment;
  final override = (env[flutterpatchDeviceIdEnvVar] ?? '').trim();
  if (override.isNotEmpty) {
    _cachedCliDeviceId = override;
    return override;
  }

  final raw = (readMachineIdRaw ?? readHostMachineIdRaw)();
  if (raw != null && raw.isNotEmpty) {
    final hash = sha256.convert(utf8.encode(raw)).toString();
    final id = 'cli_$hash';
    _cachedCliDeviceId = id;
    return id;
  }

  final id = _readOrCreatePersistedDeviceId(homePath: homePath);
  _cachedCliDeviceId = id;
  return id;
}

/// Live SHA-256 hex of the host machine-id for `X-Machine-Fingerprint`.
///
/// Order:
/// 1. [flutterpatchMachineFingerprintEnvVar] when non-empty (CI only)
/// 2. SHA-256 of live host machine-id (never from a copied device-id file)
///
/// Returns empty string when the host id cannot be resolved and no override
/// is set — callers should treat that as an error for API-key auth.
String resolveCliMachineFingerprint({
  Map<String, String>? environment,
  String? Function()? readMachineIdRaw,
}) {
  final cached = _cachedCliMachineFingerprint;
  if (cached != null) return cached;

  final env = environment ?? Platform.environment;
  final override =
      (env[flutterpatchMachineFingerprintEnvVar] ?? '').trim().toLowerCase();
  if (override.isNotEmpty) {
    _cachedCliMachineFingerprint = override;
    return override;
  }

  final raw = (readMachineIdRaw ?? readHostMachineIdRaw)();
  if (raw == null || raw.isEmpty) {
    _cachedCliMachineFingerprint = '';
    return '';
  }
  final hash = sha256.convert(utf8.encode(raw)).toString();
  _cachedCliMachineFingerprint = hash;
  return hash;
}

/// Live host machine-id used to derive the CLI device fingerprint.
String? readHostMachineIdRaw() {
  for (final path in const [
    '/etc/machine-id',
    '/var/lib/dbus/machine-id',
  ]) {
    try {
      final file = File(path);
      if (!file.existsSync()) continue;
      final text = file.readAsStringSync().trim();
      if (text.isNotEmpty) return text;
    } catch (_) {}
  }

  if (Platform.isMacOS) {
    try {
      final r = Process.runSync(
        'ioreg',
        ['-rd1', '-c', 'IOPlatformExpertDevice'],
      );
      if (r.exitCode == 0) {
        final out = '${r.stdout}';
        final m = RegExp(r'"IOPlatformUUID"\s*=\s*"([^"]+)"').firstMatch(out);
        final id = m?.group(1)?.trim();
        if (id != null && id.isNotEmpty) return id;
      }
    } catch (_) {}
  }

  if (Platform.isWindows) {
    try {
      final r = Process.runSync('reg', [
        'query',
        r'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography',
        '/v',
        'MachineGuid',
      ]);
      if (r.exitCode == 0) {
        final out = '${r.stdout}';
        final m = RegExp(
          r'MachineGuid\s+REG_SZ\s+(\S+)',
          caseSensitive: false,
        ).firstMatch(out);
        final id = m?.group(1)?.trim();
        if (id != null && id.isNotEmpty) return id;
      }
    } catch (_) {}
  }

  // macOS Docker / prior installers may already have refreshed this file.
  try {
    final home = Platform.environment['HOME']?.trim();
    if (home != null && home.isNotEmpty) {
      final file = File(p.join(home, '.flutterpatch', 'host_machine_id'));
      if (file.existsSync()) {
        final text = file.readAsStringSync().trim();
        if (text.isNotEmpty) return text;
      }
    }
  } catch (_) {}

  return null;
}

String _readOrCreatePersistedDeviceId({String? homePath}) {
  final home =
      (homePath ??
              Platform.environment['HOME'] ??
              Platform.environment['USERPROFILE'] ??
              '')
          .trim();
  if (home.isEmpty) {
    // Last resort: ephemeral per-process id (still satisfies the header).
    return 'cli_ephemeral_${DateTime.now().toUtc().microsecondsSinceEpoch}';
  }

  final file = File(p.join(home, '.flutterpatch', 'cli_device_id'));
  try {
    if (file.existsSync()) {
      final existing = file.readAsStringSync().trim();
      if (existing.isNotEmpty) return existing;
    }
  } catch (_) {}

  final random = sha256
      .convert(
        utf8.encode(
          '${DateTime.now().toUtc().microsecondsSinceEpoch}'
          '$pid'
          '${Platform.localHostname}',
        ),
      )
      .toString();
  final id = 'cli_$random';
  try {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('$id\n');
    try {
      // Best-effort private file mode on POSIX.
      Process.runSync('chmod', ['600', file.path]);
    } catch (_) {}
  } catch (_) {}
  return id;
}
