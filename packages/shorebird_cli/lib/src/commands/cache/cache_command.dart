import 'package:shorebird_cli/src/commands/commands.dart';
import 'package:shorebird_cli/src/shorebird_command.dart';

/// {@template cache_command}
/// `flutterpatch cache`
/// Manage the FlutterPatch cache.
/// {@endtemplate}
class CacheCommand extends ShorebirdCommand {
  /// {@macro cache_command}
  CacheCommand() {
    addSubcommand(CleanCacheCommand());
  }

  @override
  String get description => 'Manage the FlutterPatch cache.';

  @override
  String get name => 'cache';
}
