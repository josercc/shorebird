// flutterpatch: ownership=OURS — shared stub for control_api gaps
import 'package:mason_logger/mason_logger.dart';
import 'package:shorebird_cli/src/logging/logging.dart';

/// Prints a consistent unsupported-command message and returns [ExitCode.unavailable].
int flutterpatchUnsupported({
  required String command,
  required String reason,
  String? alternative,
}) {
  final buffer = StringBuffer()
    ..writeln('$command is not supported with FlutterPatch control_api.')
    ..writeln(reason);
  if (alternative != null && alternative.isNotEmpty) {
    buffer.writeln(alternative);
  }
  buffer.writeln(
    'See flutterpatch docs/cli-shorebird-fork.md for the command matrix.',
  );
  logger.err(buffer.toString().trimRight());
  return ExitCode.unavailable.code;
}
