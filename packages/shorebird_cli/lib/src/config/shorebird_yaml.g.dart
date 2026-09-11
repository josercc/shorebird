// GENERATED CODE - DO NOT MODIFY BY HAND

// ignore_for_file: implicit_dynamic_parameter, require_trailing_commas, cast_nullable_to_non_nullable, lines_longer_than_80_chars, strict_raw_type, unnecessary_lambdas

part of 'shorebird_yaml.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ShorebirdYaml _$ShorebirdYamlFromJson(Map json) => $checkedCreate(
  'ShorebirdYaml',
  json,
  ($checkedConvert) {
    $checkKeys(
      json,
      allowedKeys: const [
        'app_id',
        'flavors',
        'base_url',
        'auto_update',
        'patch_verification',
        'upload_baselines',
        'upload_patch_resources',
        'flutter',
        'android',
        'ios',
      ],
    );
    final val = ShorebirdYaml(
      appId: $checkedConvert('app_id', (v) => v as String),
      flavors: $checkedConvert(
        'flavors',
        (v) => (v as Map?)?.map((k, e) => MapEntry(k as String, e as String)),
      ),
      baseUrl: $checkedConvert('base_url', (v) => v as String?),
      autoUpdate: $checkedConvert('auto_update', (v) => v as bool?),
      patchVerification: $checkedConvert(
        'patch_verification',
        (v) => $enumDecodeNullable(_$PatchVerificationEnumMap, v),
      ),
      uploadBaselines: $checkedConvert(
        'upload_baselines',
        (v) => v as bool?,
      ),
      uploadPatchResources: $checkedConvert(
        'upload_patch_resources',
        (v) => v as bool?,
      ),
      flutter: $checkedConvert('flutter', (v) => v as String?),
      android: $checkedConvert('android', (v) => v as String?),
      ios: $checkedConvert('ios', (v) => v as String?),
    );
    return val;
  },
  fieldKeyMap: const {
    'appId': 'app_id',
    'baseUrl': 'base_url',
    'autoUpdate': 'auto_update',
    'patchVerification': 'patch_verification',
    'uploadBaselines': 'upload_baselines',
    'uploadPatchResources': 'upload_patch_resources',
  },
);

Map<String, dynamic> _$ShorebirdYamlToJson(
  ShorebirdYaml instance,
) => <String, dynamic>{
  'app_id': instance.appId,
  'flavors': instance.flavors,
  'base_url': instance.baseUrl,
  'auto_update': instance.autoUpdate,
  'patch_verification': _$PatchVerificationEnumMap[instance.patchVerification],
  'upload_baselines': instance.uploadBaselines,
  'upload_patch_resources': instance.uploadPatchResources,
  'flutter': instance.flutter,
  'android': instance.android,
  'ios': instance.ios,
};

const _$PatchVerificationEnumMap = {
  PatchVerification.strict: 'strict',
  PatchVerification.installOnly: 'install_only',
};
