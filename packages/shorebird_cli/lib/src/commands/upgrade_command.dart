// flutterpatch: ownership=REPLACE
import 'package:shorebird_cli/src/flutterpatch_unsupported.dart';
import 'package:shorebird_cli/src/shorebird_command.dart';

/// {@template upgrade_command}
/// `flutterpatch upgrade` — stubbed; self-update channel not wired yet.
/// {@endtemplate}
class UpgradeCommand extends ShorebirdCommand {
  /// {@macro upgrade_command}
  UpgradeCommand();

  @override
  String get description =>
      'Upgrade FlutterPatch CLI (not wired to a release channel yet).';

  /// Name of the command.
  static const String commandName = 'upgrade';

  @override
  String get name => commandName;

  @override
  Future<int> run() async {
    return flutterpatchUnsupported(
      command: 'upgrade',
      reason:
          'This fork does not auto-update from a release channel. Pull the '
          'latest FlutterPatch CLI instead.',
      alternative:
          'cd your shorebird fork && git pull (or merge upstream per '
          'docs/cli-shorebird-fork.md)',
    );
  }
}
