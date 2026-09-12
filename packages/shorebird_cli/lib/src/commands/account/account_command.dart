import 'package:shorebird_cli/src/commands/account/account.dart';
import 'package:shorebird_cli/src/shorebird_command.dart';

/// {@template account_command}
/// Commands for inspecting the current FlutterPatch account.
/// {@endtemplate}
class AccountCommand extends ShorebirdCommand {
  /// {@macro account_command}
  AccountCommand() {
    addSubcommand(AccountAppsCommand());
    addSubcommand(AccountLoginCommand());
    addSubcommand(OrgsCommand());
  }

  @override
  String get name => 'account';

  @override
  String get description => 'Manage your FlutterPatch account.';
}
