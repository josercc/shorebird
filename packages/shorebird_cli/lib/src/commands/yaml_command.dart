import 'package:mason_logger/mason_logger.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/shorebird_command.dart';

/// Documentation for a single `shorebird.yaml` field.
typedef ShorebirdYamlFieldDoc = ({
  String name,
  bool required,
  String type,
  String description,
  /// Default when the key is omitted from `shorebird.yaml`.
  String defaultValue,
  String? example,
  List<String>? values,
});

/// Supported `shorebird.yaml` fields and their descriptions.
const shorebirdYamlFieldDocs = <ShorebirdYamlFieldDoc>[
  (
    name: 'app_id',
    required: true,
    type: 'string',
    description: 'The base FlutterPatch app id for this project.',
    defaultValue: 'none (required)',
    example: '8d3155a8-a048-4820-acca-824d26c29b71',
    values: null,
  ),
  (
    name: 'flavors',
    required: false,
    type: 'map<string, string>',
    description:
        'Maps product flavor names to app ids. Omit when the app has no '
        'flavors. When set, `--flavor` selects the matching app id.',
    defaultValue: 'none',
    example: '''
flavors:
  development: 8d3155a8-a048-4820-acca-824d26c29b71
  production: d458e87a-7362-4386-9eeb-629db2af413a''',
    values: null,
  ),
  (
    name: 'base_url',
    required: false,
    type: 'string',
    description:
        'Base URL used to check for updates and talk to the FlutterPatch '
        'control API. Written by `flutterpatch init` when a control API URL '
        'is provided.',
    defaultValue: 'none',
    example: 'https://api.example.com',
    values: null,
  ),
  (
    name: 'patch_verification',
    required: false,
    type: 'string',
    description:
        'How the app verifies patch signatures and hashes at install/load '
        'time. Has no effect unless patch signing is enabled for the release.',
    defaultValue: 'strict (when patch signing is enabled)',
    example: 'strict',
    values: ['strict', 'install_only'],
  ),
  (
    name: 'upload_baselines',
    required: false,
    type: 'bool',
    description:
        'When true, `flutterpatch release` uploads OTA snapshot and resource '
        'baselines for the released platform after a successful publish. '
        'Equivalent to passing `--upload-baselines` on the CLI.',
    defaultValue: 'false',
    example: 'true',
    values: null,
  ),
  (
    name: 'upload_patch_resources',
    required: false,
    type: 'bool',
    description:
        'When true, `flutterpatch patch` scans local Flutter assets, diffs '
        'against the server resource baseline for the target release version, '
        'and attaches changed resources when publishing the patch. Explicit '
        '`--assets` / `--baseline-assets` still take precedence.',
    defaultValue: 'false',
    example: 'true',
    values: null,
  ),
];

/// {@template yaml_command}
/// `flutterpatch yaml`
/// Prints documentation for supported `shorebird.yaml` fields.
/// {@endtemplate}
class YamlCommand extends ShorebirdCommand {
  /// {@macro yaml_command}
  YamlCommand();

  @override
  String get name => 'yaml';

  @override
  String get description =>
      'Print documentation for supported shorebird.yaml fields.\n'
      '${ShorebirdCommand.jsonHint('flutterpatch yaml --json')}';

  @override
  Future<int> run() async {
    if (isJsonMode) {
      emitJsonSuccess({
        'file': 'shorebird.yaml',
        'fields': [
          for (final field in shorebirdYamlFieldDocs)
            {
              'name': field.name,
              'required': field.required,
              'type': field.type,
              'description': field.description,
              'default': field.defaultValue,
              if (field.example != null) 'example': field.example,
              if (field.values != null) 'values': field.values,
            },
        ],
      });
      return ExitCode.success.code;
    }

    final buffer = StringBuffer()
      ..writeln('shorebird.yaml')
      ..writeln()
      ..writeln(
        'FlutterPatch configuration file placed in the project root '
        '(usually created by `flutterpatch init`).',
      )
      ..writeln('Unrecognized keys are rejected.')
      ..writeln()
      ..writeln('Fields:');

    for (final field in shorebirdYamlFieldDocs) {
      final requirement = field.required ? 'required' : 'optional';
      buffer
        ..writeln()
        ..writeln('  ${field.name} ($requirement, ${field.type})')
        ..writeln('    ${field.description}')
        ..writeln('    Default: ${field.defaultValue}');
      if (field.values != null) {
        buffer.writeln('    Allowed values: ${field.values!.join(', ')}');
      }
      if (field.example != null) {
        final exampleLines = field.example!.split('\n');
        if (exampleLines.length == 1) {
          buffer.writeln('    Example: ${field.example}');
        } else {
          buffer.writeln('    Example:');
          for (final line in exampleLines) {
            buffer.writeln('      $line');
          }
        }
      }
    }

    buffer
      ..writeln()
      ..writeln('Minimal example:')
      ..writeln()
      ..writeln('  app_id: 8d3155a8-a048-4820-acca-824d26c29b71')
      ..writeln('  base_url: https://api.example.com');

    logger.info(buffer.toString());
    return ExitCode.success.code;
  }
}
