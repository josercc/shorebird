import 'package:shorebird_cli/src/commands/commands.dart';
import 'package:shorebird_cli/src/shorebird_command.dart';

/// {@template flutter_versions_command}
/// `flutterpatch flutter versions`
/// Manage your FlutterPatch Flutter versions.
/// {@endtemplate}
class FlutterVersionsCommand extends ShorebirdCommand {
  /// {@macro flutter_versions_command}
  FlutterVersionsCommand() {
    addSubcommand(FlutterVersionsListCommand());
  }

  @override
  String get description => 'Manage your FlutterPatch Flutter versions.';

  @override
  String get name => 'versions';
}
