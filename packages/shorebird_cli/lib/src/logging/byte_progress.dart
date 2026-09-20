import 'package:shorebird_cli/src/interactive_mode.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';

/// Formats [bytes] as `B`, `KB`, `MB`, or `GB`.
String formatByteSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var size = bytes / 1024;
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  return '${size.toStringAsFixed(1)} ${units[unit]}';
}

/// `1.2 MB / 8.4 MB (14%)`, or just the received size when [totalBytes] is
/// unknown.
String formatByteProgress(int receivedBytes, int? totalBytes) {
  final received = formatByteSize(receivedBytes);
  if (totalBytes == null || totalBytes <= 0) return received;
  final percent = (receivedBytes * 100 / totalBytes).clamp(0, 100).round();
  return '$received / ${formatByteSize(totalBytes)} ($percent%)';
}

/// Throttles byte-progress lines so interactive spinners stay smooth and
/// non-interactive logs do not print one line per chunk.
class ByteProgressUpdater {
  /// Creates an updater that calls [onUpdate] with `label size` messages.
  ByteProgressUpdater({
    required void Function(String update) onUpdate,
    this.minInterval = const Duration(milliseconds: 250),
    this.minPercentStep = 1,
  }) : _onUpdate = onUpdate;

  final void Function(String update) _onUpdate;

  /// Minimum time between updates when the total size is unknown.
  final Duration minInterval;

  /// Minimum percent change required before another update is printed.
  final int minPercentStep;

  DateTime? _lastEmit;
  int _lastPercent = -1;
  String? _lastMessage;

  /// Reports [receivedBytes] of [totalBytes] under [label].
  void report({
    required String label,
    required int receivedBytes,
    int? totalBytes,
  }) {
    final percent = (totalBytes != null && totalBytes > 0)
        ? (receivedBytes * 100 / totalBytes).floor().clamp(0, 100)
        : null;
    final message = '$label ${formatByteProgress(receivedBytes, totalBytes)}';
    if (message == _lastMessage) return;

    final now = DateTime.now();
    if (percent != null) {
      final advanced =
          _lastPercent < 0 || percent >= _lastPercent + minPercentStep;
      final finished = percent >= 100;
      if (!advanced && !finished) return;
      _lastPercent = percent;
    } else if (_lastEmit != null &&
        now.difference(_lastEmit!) < minInterval) {
      return;
    }

    _lastEmit = now;
    _lastMessage = message;
    _onUpdate(message);
  }
}

/// Forwards artifact-download events to the active [Progress] message.
class ArtifactDownloadProgressSink {
  ByteProgressUpdater? _updater;

  /// Attaches [onUpdate] for the duration of a fetch.
  void bind(void Function(String update) onUpdate) {
    _updater = ByteProgressUpdater(
      onUpdate: onUpdate,
      minPercentStep: isInteractive ? 1 : 5,
    );
  }

  /// Stops forwarding events.
  void unbind() {
    _updater = null;
  }

  /// Handles a download event from [CodePushClient].
  void add(ArtifactDownloadProgress event) {
    _updater?.report(
      label: 'Downloading ${event.label}',
      receivedBytes: event.receivedBytes,
      totalBytes: event.totalBytes,
    );
  }
}
