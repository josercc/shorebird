import 'dart:io';

import 'package:args/args.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/code_signer.dart';
import 'package:shorebird_cli/src/commands/commands.dart';
import 'package:shorebird_cli/src/common_arguments.dart';
import 'package:shorebird_cli/src/config/config.dart';
import 'package:shorebird_cli/src/deployment_track.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/patch_diff_checker.dart';
import 'package:shorebird_cli/src/platform/platform.dart';
import 'package:shorebird_cli/src/release_type.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/third_party/flutter_tools/lib/flutter_tools.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';
import 'package:test/test.dart';

import '../../mocks.dart';

class FakeFile extends Fake implements File {}

void main() {
  group(Patcher, () {
    setUpAll(() {
      registerFallbackValue(ReleasePlatform.android);
      registerFallbackValue(DeploymentTrack.stable);
      registerFallbackValue(FakeFile());
    });

    group('linkPercentage', () {
      test('defaults to null', () {
        expect(
          _TestPatcher(
            argParser: MockArgParser(),
            argResults: MockArgResults(),
            flavor: null,
            target: null,
          ).linkPercentage,
          isNull,
        );
      });
    });

    group('supplementaryReleaseArtifactArch', () {
      test('defaults to null', () {
        expect(
          _TestPatcher(
            argParser: MockArgParser(),
            argResults: MockArgResults(),
            flavor: null,
            target: null,
          ).supplementaryReleaseArtifactArch,
          isNull,
        );
      });
    });

    group('assertArgsAreValid', () {
      test('has no validations by default', () {
        expect(
          _TestPatcher(
            argParser: MockArgParser(),
            argResults: MockArgResults(),
            flavor: null,
            target: null,
          ).assertArgsAreValid,
          returnsNormally,
        );
      });
    });

    group('buildNameAndNumberArgsFromReleaseVersion', () {
      late ArgResults argResults;
      setUp(() {
        argResults = MockArgResults();
        when(() => argResults.options).thenReturn([]);
      });

      group('when releaseVersion is not specified', () {
        test('returns an empty list', () {
          expect(
            _TestPatcher(
              argParser: MockArgParser(),
              argResults: MockArgResults(),
              flavor: null,
              target: null,
            ).buildNameAndNumberArgsFromReleaseVersion(null),
            isEmpty,
          );
        });
      });

      group('when an invalid --release-version is specified', () {
        test('returns an empty list', () {
          expect(
            _TestPatcher(
              argParser: MockArgParser(),
              argResults: argResults,
              flavor: null,
              target: null,
            ).buildNameAndNumberArgsFromReleaseVersion('invalid'),
            isEmpty,
          );
        });
      });

      group('when a valid --release-version is specified', () {
        group('when --build-name is specified', () {
          setUp(() {
            when(() => argResults.rest).thenReturn(['--build-name=foo']);
          });

          test('returns an empty list', () {
            expect(
              _TestPatcher(
                argParser: MockArgParser(),
                argResults: argResults,
                flavor: null,
                target: null,
              ).buildNameAndNumberArgsFromReleaseVersion('1.2.3+4'),
              isEmpty,
            );
          });
        });

        group('when --build-number is specified', () {
          setUp(() {
            when(() => argResults.rest).thenReturn(['--build-number=42']);
          });

          test('returns an empty list', () {
            expect(
              _TestPatcher(
                argParser: MockArgParser(),
                argResults: argResults,
                flavor: null,
                target: null,
              ).buildNameAndNumberArgsFromReleaseVersion('1.2.3+4'),
              isEmpty,
            );
          });
        });

        group('when neither --build-name nor --build-number are specified', () {
          test('returns --build-name and --build-number', () {
            when(() => argResults.rest).thenReturn([]);

            expect(
              _TestPatcher(
                argParser: MockArgParser(),
                argResults: argResults,
                flavor: null,
                target: null,
              ).buildNameAndNumberArgsFromReleaseVersion('1.2.3+4'),
              equals(['--build-name=1.2.3', '--build-number=4']),
            );
          });
        });

        group('when build-name and build-number were parsed as options', () {
          setUp(() {
            when(
              () => argResults.wasParsed(CommonArguments.buildNameArg.name),
            ).thenReturn(true);
            when(
              () => argResults.wasParsed(CommonArguments.buildNumberArg.name),
            ).thenReturn(true);
            when(() => argResults.options).thenReturn([
              'release-version',
              'build-name',
              'build-number',
              'platforms',
            ]);
          });

          test('returns an empty list', () {
            expect(
              _TestPatcher(
                argParser: MockArgParser(),
                argResults: argResults,
                flavor: null,
                target: null,
              ).buildNameAndNumberArgsFromReleaseVersion('1.2.3+4'),
              isEmpty,
            );
          });
        });
      });
    });

    group('uploadPatchArtifacts', () {
      test('calls codePushClientWrapper.publishPatch '
          'with correct args', () async {
        final argParser = ArgParser()
          ..addOption('assets')
          ..addOption('baseline-assets')
          ..addOption('resource-number')
          ..addFlag('upload-assets', defaultsTo: true)
          ..addFlag('force-duplicate-resources', negatable: false)
          ..addFlag('whitelist')
          ..addMultiOption('unique-ids');
        final args = argParser.parse([]);
        final patcher = _TestPatcher(
          argParser: argParser,
          argResults: args,
          flavor: null,
          target: null,
          releaseType: ReleaseType.android,
        );
        const appId = 'test_app_id';
        const releaseId = 42;
        const metadata = <String, String>{};
        const artifacts = <Arch, PatchArtifactBundle>{};
        const track = DeploymentTrack.stable;
        final codePushClientWrapper = MockCodePushClientWrapper();
        final shorebirdEnv = MockShorebirdEnv();
        when(() => shorebirdEnv.getShorebirdYaml()).thenReturn(
          const ShorebirdYaml(appId: appId),
        );
        when(
          () => codePushClientWrapper.publishPatch(
            appId: any(named: 'appId'),
            releaseId: any(named: 'releaseId'),
            metadata: any(named: 'metadata'),
            platform: any(named: 'platform'),
            track: any(named: 'track'),
            patchArtifactBundles: any(named: 'patchArtifactBundles'),
            force: any(named: 'force'),
          ),
        ).thenAnswer((_) async {});
        await runScoped(
          () async {
            await patcher.uploadPatchArtifacts(
              appId: appId,
              releaseId: releaseId,
              releaseVersion: '1.0.0+1',
              metadata: metadata,
              artifacts: artifacts,
              track: track,
            );
          },
          values: {
            codePushClientWrapperRef.overrideWith(() => codePushClientWrapper),
            shorebirdEnvRef.overrideWith(() => shorebirdEnv),
          },
        );
        verify(
          () => codePushClientWrapper.publishPatch(
            appId: appId,
            releaseId: releaseId,
            metadata: metadata,
            platform: ReleaseType.android.releasePlatform,
            track: track,
            patchArtifactBundles: artifacts,
            force: false,
          ),
        ).called(1);
      });

      test('exits when compare finds duplicate changed_resources', () async {
        final temp = Directory.systemTemp.createTempSync('patch_dedup_');
        addTearDown(() => temp.deleteSync(recursive: true));
        final baseline = File(p.join(temp.path, 'baseline.json'))
          ..writeAsStringSync(
            '''
{
  "release_version": "1.0.0+1",
  "count": 1,
  "resources": [
    {"package": "app", "path": "assets/a.png", "hash": "old", "size": 1}
  ]
}
''',
          );
        final assets = File(p.join(temp.path, 'assets.json'))
          ..writeAsStringSync(
            '''
{
  "release_version": "1.0.0+1",
  "count": 1,
  "resources": [
    {"package": "app", "path": "assets/a.png", "hash": "new", "size": 2}
  ]
}
''',
          );

        final argParser = ArgParser()
          ..addOption('assets')
          ..addOption('baseline-assets')
          ..addOption('resource-number')
          ..addFlag('upload-assets', defaultsTo: true)
          ..addFlag('force-duplicate-resources', negatable: false)
          ..addFlag('whitelist')
          ..addMultiOption('unique-ids');
        final args = argParser.parse([
          '--assets=${assets.path}',
          '--baseline-assets=${baseline.path}',
          '--no-upload-assets',
        ]);
        final patcher = _TestPatcher(
          argParser: argParser,
          argResults: args,
          flavor: null,
          target: null,
          releaseType: ReleaseType.android,
        );
        final codePushClientWrapper = MockCodePushClientWrapper();
        final codePushClient = MockCodePushClient();
        final logger = MockShorebirdLogger();
        final shorebirdEnv = MockShorebirdEnv();
        when(() => shorebirdEnv.getShorebirdYaml()).thenReturn(
          const ShorebirdYaml(appId: 'test_app_id'),
        );
        when(() => codePushClientWrapper.codePushClient)
            .thenReturn(codePushClient);
        when(
          () => codePushClient.comparePatchResources(
            appId: any(named: 'appId'),
            releaseVersion: any(named: 'releaseVersion'),
            platform: any(named: 'platform'),
            arch: any(named: 'arch'),
            changedResources: any(named: 'changedResources'),
          ),
        ).thenAnswer(
          (_) async => const PatchResourcesCompareResult(
            duplicate: true,
            matchingPatchNumber: 3,
            matchingPatchId: 'patch-3',
          ),
        );

        await expectLater(
          () => runScoped(
            () async {
              await patcher.uploadPatchArtifacts(
                appId: 'test_app_id',
                releaseId: 42,
                releaseVersion: '1.0.0+1',
                metadata: const {},
                artifacts: {
                  Arch.arm64: const PatchArtifactBundle(
                    arch: 'aarch64',
                    path: '/tmp/a.patch',
                    hash: 'abc',
                    size: 1,
                  ),
                },
                track: DeploymentTrack.stable,
              );
            },
            values: {
              codePushClientWrapperRef.overrideWith(
                () => codePushClientWrapper,
              ),
              shorebirdEnvRef.overrideWith(() => shorebirdEnv),
              loggerRef.overrideWith(() => logger),
            },
          ),
          throwsA(
            isA<ProcessExit>().having((e) => e.exitCode, 'exitCode', isNonZero),
          ),
        );
        verifyNever(
          () => codePushClientWrapper.publishPatch(
            appId: any(named: 'appId'),
            releaseId: any(named: 'releaseId'),
            metadata: any(named: 'metadata'),
            platform: any(named: 'platform'),
            track: any(named: 'track'),
            patchArtifactBundles: any(named: 'patchArtifactBundles'),
            force: any(named: 'force'),
          ),
        );
        verify(
          () => logger.err(any(that: contains('补丁 #3'))),
        ).called(1);
      });

      test('force-duplicate-resources skips compare and publishes', () async {
        final temp = Directory.systemTemp.createTempSync('patch_force_');
        addTearDown(() => temp.deleteSync(recursive: true));
        final baseline = File(p.join(temp.path, 'baseline.json'))
          ..writeAsStringSync(
            '''
{
  "release_version": "1.0.0+1",
  "count": 1,
  "resources": [
    {"package": "app", "path": "assets/a.png", "hash": "old", "size": 1}
  ]
}
''',
          );
        final assets = File(p.join(temp.path, 'assets.json'))
          ..writeAsStringSync(
            '''
{
  "release_version": "1.0.0+1",
  "count": 1,
  "resources": [
    {"package": "app", "path": "assets/a.png", "hash": "new", "size": 2}
  ]
}
''',
          );

        final argParser = ArgParser()
          ..addOption('assets')
          ..addOption('baseline-assets')
          ..addOption('resource-number')
          ..addFlag('upload-assets', defaultsTo: true)
          ..addFlag('force-duplicate-resources', negatable: false)
          ..addFlag('whitelist')
          ..addMultiOption('unique-ids');
        final args = argParser.parse([
          '--assets=${assets.path}',
          '--baseline-assets=${baseline.path}',
          '--no-upload-assets',
          '--force-duplicate-resources',
        ]);
        final patcher = _TestPatcher(
          argParser: argParser,
          argResults: args,
          flavor: null,
          target: null,
          releaseType: ReleaseType.android,
        );
        final codePushClientWrapper = MockCodePushClientWrapper();
        final codePushClient = MockCodePushClient();
        final shorebirdEnv = MockShorebirdEnv();
        when(() => shorebirdEnv.getShorebirdYaml()).thenReturn(
          const ShorebirdYaml(appId: 'test_app_id'),
        );
        when(() => codePushClientWrapper.codePushClient)
            .thenReturn(codePushClient);
        when(
          () => codePushClientWrapper.publishPatch(
            appId: any(named: 'appId'),
            releaseId: any(named: 'releaseId'),
            metadata: any(named: 'metadata'),
            platform: any(named: 'platform'),
            track: any(named: 'track'),
            patchArtifactBundles: any(named: 'patchArtifactBundles'),
            changedResources: any(named: 'changedResources'),
            force: any(named: 'force'),
          ),
        ).thenAnswer((_) async {});

        await runScoped(
          () async {
            await patcher.uploadPatchArtifacts(
              appId: 'test_app_id',
              releaseId: 42,
              releaseVersion: '1.0.0+1',
              metadata: const {},
              artifacts: {
                Arch.arm64: const PatchArtifactBundle(
                  arch: 'aarch64',
                  path: '/tmp/a.patch',
                  hash: 'abc',
                  size: 1,
                ),
              },
              track: DeploymentTrack.stable,
            );
          },
          values: {
            codePushClientWrapperRef.overrideWith(() => codePushClientWrapper),
            shorebirdEnvRef.overrideWith(() => shorebirdEnv),
          },
        );

        verifyNever(
          () => codePushClient.comparePatchResources(
            appId: any(named: 'appId'),
            releaseVersion: any(named: 'releaseVersion'),
            platform: any(named: 'platform'),
            arch: any(named: 'arch'),
            changedResources: any(named: 'changedResources'),
          ),
        );
        verify(
          () => codePushClientWrapper.publishPatch(
            appId: 'test_app_id',
            releaseId: 42,
            metadata: any(named: 'metadata'),
            platform: ReleasePlatform.android,
            track: DeploymentTrack.stable,
            patchArtifactBundles: any(named: 'patchArtifactBundles'),
            changedResources: any(named: 'changedResources'),
            force: true,
          ),
        ).called(1);
      });

      test('exits when ignore-listed resources changed', () async {
        final temp = Directory.systemTemp.createTempSync('patch_unsupported_');
        addTearDown(() => temp.deleteSync(recursive: true));
        File(p.join(temp.path, '.flutterpatch-unsupported-resources')).writeAsStringSync(
          'assets/fonts/**\n',
        );
        final baseline = File(p.join(temp.path, 'baseline.json'))
          ..writeAsStringSync(
            '''
{
  "release_version": "1.0.0+1",
  "count": 1,
  "resources": [
    {"package": "app", "path": "assets/fonts/Roboto.ttf", "hash": "old", "size": 1}
  ]
}
''',
          );
        final assets = File(p.join(temp.path, 'assets.json'))
          ..writeAsStringSync(
            '''
{
  "release_version": "1.0.0+1",
  "count": 1,
  "resources": [
    {"package": "app", "path": "assets/fonts/Roboto.ttf", "hash": "new", "size": 2}
  ]
}
''',
          );

        final argParser = ArgParser()
          ..addOption('assets')
          ..addOption('baseline-assets')
          ..addOption('resource-number')
          ..addFlag('upload-assets', defaultsTo: true)
          ..addFlag('force-duplicate-resources', negatable: false)
          ..addFlag('whitelist')
          ..addMultiOption('unique-ids');
        final args = argParser.parse([
          '--assets=${assets.path}',
          '--baseline-assets=${baseline.path}',
          '--no-upload-assets',
        ]);
        final patcher = _TestPatcher(
          argParser: argParser,
          argResults: args,
          flavor: null,
          target: null,
          releaseType: ReleaseType.android,
        );
        final codePushClientWrapper = MockCodePushClientWrapper();
        final logger = MockShorebirdLogger();
        final shorebirdEnv = MockShorebirdEnv();
        when(() => shorebirdEnv.getShorebirdYaml()).thenReturn(
          ShorebirdYaml(appId: 'test_app_id', flutter: temp.path),
        );
        when(() => logger.err(any())).thenReturn(null);

        await expectLater(
          () => runScoped(
            () async {
              await patcher.uploadPatchArtifacts(
                appId: 'test_app_id',
                releaseId: 42,
                releaseVersion: '1.0.0+1',
                metadata: const {},
                artifacts: {
                  Arch.arm64: const PatchArtifactBundle(
                    arch: 'aarch64',
                    path: '/tmp/a.patch',
                    hash: 'abc',
                    size: 1,
                  ),
                },
                track: DeploymentTrack.stable,
              );
            },
            values: {
              codePushClientWrapperRef.overrideWith(() => codePushClientWrapper),
              loggerRef.overrideWith(() => logger),
              shorebirdEnvRef.overrideWith(() => shorebirdEnv),
            },
          ),
          throwsA(
            isA<ProcessExit>().having((e) => e.exitCode, 'exitCode', isNonZero),
          ),
        );

        verify(
          () => logger.err(any(that: contains('不支持热更'))),
        ).called(1);
        verifyNever(
          () => codePushClientWrapper.publishPatch(
            appId: any(named: 'appId'),
            releaseId: any(named: 'releaseId'),
            metadata: any(named: 'metadata'),
            platform: any(named: 'platform'),
            track: any(named: 'track'),
            patchArtifactBundles: any(named: 'patchArtifactBundles'),
          ),
        );
      });
    });

    group('signHash', () {
      final cryptoFixturesBasePath = p.join('test', 'fixtures', 'crypto');
      final privateKeyFile = File(
        p.join(cryptoFixturesBasePath, 'private.pem'),
      );

      late ArgParser argParser;
      late ArgResults argResults;
      late CodeSigner codeSigner;
      late ShorebirdLogger logger;
      late File publicKeyTempFile;

      setUp(() {
        argParser = ArgParser()
          ..addOption(CommonArguments.publicKeyArg.name)
          ..addOption(CommonArguments.privateKeyArg.name)
          ..addOption(CommonArguments.publicKeyCmd.name)
          ..addOption(CommonArguments.signCmd.name);
        codeSigner = MockCodeSigner();
        logger = MockShorebirdLogger();
        publicKeyTempFile = File(
          p.join(
            Directory.systemTemp.createTempSync().path,
            'public.pem',
          ),
        )..writeAsStringSync('fake-public-key-pem');
      });

      test('returns null when no signing is configured', () async {
        argResults = argParser.parse([]);

        final patcher = _TestPatcher(
          argParser: argParser,
          argResults: argResults,
          flavor: null,
          target: null,
        );

        await runScoped(
          () async {
            final result = await patcher.signHash('test-hash');
            expect(result, isNull);
          },
          values: {codeSignerRef.overrideWith(() => codeSigner)},
        );
      });

      test('returns signature from file-based signing', () async {
        argResults = argParser.parse([
          '--${CommonArguments.publicKeyArg.name}=${publicKeyTempFile.path}',
          '--${CommonArguments.privateKeyArg.name}=${privateKeyFile.path}',
        ]);

        when(
          () => codeSigner.sign(
            message: any(named: 'message'),
            privateKeyPemFile: any(named: 'privateKeyPemFile'),
          ),
        ).thenReturn('file-signature');
        when(
          () => codeSigner.verify(
            message: any(named: 'message'),
            signature: any(named: 'signature'),
            publicKeyPem: any(named: 'publicKeyPem'),
          ),
        ).thenReturn(true);

        final patcher = _TestPatcher(
          argParser: argParser,
          argResults: argResults,
          flavor: null,
          target: null,
        );

        await runScoped(
          () async {
            final result = await patcher.signHash('test-hash');
            expect(result, equals('file-signature'));
          },
          values: {codeSignerRef.overrideWith(() => codeSigner)},
        );
      });

      test(
        'throws ProcessExit when signer present but no public key',
        () async {
          argResults = argParser.parse([
            '--${CommonArguments.privateKeyArg.name}=${privateKeyFile.path}',
          ]);

          when(
            () => codeSigner.sign(
              message: any(named: 'message'),
              privateKeyPemFile: any(named: 'privateKeyPemFile'),
            ),
          ).thenReturn('file-signature');

          final patcher = _TestPatcher(
            argParser: argParser,
            argResults: argResults,
            flavor: null,
            target: null,
          );

          await runScoped(
            () async {
              await expectLater(
                () => patcher.signHash('test-hash'),
                throwsA(isA<ProcessExit>()),
              );
              verify(
                () => logger.err(
                  any(that: contains('public key is required')),
                ),
              ).called(1);
            },
            values: {
              codeSignerRef.overrideWith(() => codeSigner),
              loggerRef.overrideWith(() => logger),
            },
          );
        },
      );

      test('returns signature from command-based signing when valid', () async {
        argResults = argParser.parse([
          '--${CommonArguments.publicKeyCmd.name}=get-key-cmd',
          '--${CommonArguments.signCmd.name}=sign-cmd',
        ]);

        when(
          () => codeSigner.signWithCmd(
            data: any(named: 'data'),
            command: any(named: 'command'),
          ),
        ).thenAnswer((_) async => 'cmd-signature');
        when(
          () => codeSigner.runPublicKeyCmd(any()),
        ).thenAnswer((_) async => 'pem-public-key');
        when(
          () => codeSigner.verify(
            message: any(named: 'message'),
            signature: any(named: 'signature'),
            publicKeyPem: any(named: 'publicKeyPem'),
          ),
        ).thenReturn(true);

        final patcher = _TestPatcher(
          argParser: argParser,
          argResults: argResults,
          flavor: null,
          target: null,
        );

        await runScoped(
          () async {
            final result = await patcher.signHash('test-hash');
            expect(result, equals('cmd-signature'));
            verify(
              () => codeSigner.signWithCmd(
                data: 'test-hash',
                command: 'sign-cmd',
              ),
            ).called(1);
            verify(() => codeSigner.runPublicKeyCmd('get-key-cmd')).called(1);
            verify(
              () => codeSigner.verify(
                message: 'test-hash',
                signature: 'cmd-signature',
                publicKeyPem: 'pem-public-key',
              ),
            ).called(1);
          },
          values: {codeSignerRef.overrideWith(() => codeSigner)},
        );
      });

      test('throws ProcessExit when sign-cmd fails', () async {
        argResults = argParser.parse([
          '--${CommonArguments.publicKeyCmd.name}=get-key-cmd',
          '--${CommonArguments.signCmd.name}=bad-cmd',
        ]);

        when(
          () => codeSigner.signWithCmd(
            data: any(named: 'data'),
            command: any(named: 'command'),
          ),
        ).thenThrow(
          const ProcessException('bad-cmd', [], 'command not found', 127),
        );

        final patcher = _TestPatcher(
          argParser: argParser,
          argResults: argResults,
          flavor: null,
          target: null,
        );

        await runScoped(
          () async {
            await expectLater(
              () => patcher.signHash('test-hash'),
              throwsA(isA<ProcessExit>()),
            );
            verify(
              () => logger.err(any(that: contains('--sign-cmd'))),
            ).called(1);
          },
          values: {
            codeSignerRef.overrideWith(() => codeSigner),
            loggerRef.overrideWith(() => logger),
          },
        );
      });

      test('throws ProcessExit when public-key-cmd fails', () async {
        argResults = argParser.parse([
          '--${CommonArguments.publicKeyCmd.name}=bad-key-cmd',
          '--${CommonArguments.signCmd.name}=sign-cmd',
        ]);

        when(
          () => codeSigner.signWithCmd(
            data: any(named: 'data'),
            command: any(named: 'command'),
          ),
        ).thenAnswer((_) async => 'signature');
        when(
          () => codeSigner.runPublicKeyCmd(any()),
        ).thenThrow(
          const ProcessException(
            'bad-key-cmd',
            [],
            'command not found',
            127,
          ),
        );

        final patcher = _TestPatcher(
          argParser: argParser,
          argResults: argResults,
          flavor: null,
          target: null,
        );

        await runScoped(
          () async {
            await expectLater(
              () => patcher.signHash('test-hash'),
              throwsA(isA<ProcessExit>()),
            );
            verify(
              () => logger.err(any(that: contains('--public-key-cmd'))),
            ).called(1);
          },
          values: {
            codeSignerRef.overrideWith(() => codeSigner),
            loggerRef.overrideWith(() => logger),
          },
        );
      });

      test('supports mixed signing (public key file + sign cmd)', () async {
        argResults = argParser.parse([
          '--${CommonArguments.publicKeyArg.name}=${publicKeyTempFile.path}',
          '--${CommonArguments.signCmd.name}=sign-cmd',
        ]);

        when(
          () => codeSigner.signWithCmd(
            data: any(named: 'data'),
            command: any(named: 'command'),
          ),
        ).thenAnswer((_) async => 'cmd-signature');
        when(
          () => codeSigner.verify(
            message: any(named: 'message'),
            signature: any(named: 'signature'),
            publicKeyPem: any(named: 'publicKeyPem'),
          ),
        ).thenReturn(true);

        final patcher = _TestPatcher(
          argParser: argParser,
          argResults: argResults,
          flavor: null,
          target: null,
        );

        await runScoped(
          () async {
            final result = await patcher.signHash('test-hash');
            expect(result, equals('cmd-signature'));
            verifyNever(() => codeSigner.runPublicKeyCmd(any()));
            verify(
              () => codeSigner.verify(
                message: 'test-hash',
                signature: 'cmd-signature',
                publicKeyPem: any(named: 'publicKeyPem'),
              ),
            ).called(1);
          },
          values: {codeSignerRef.overrideWith(() => codeSigner)},
        );
      });

      test('throws ProcessExit when signature verification fails', () async {
        argResults = argParser.parse([
          '--${CommonArguments.publicKeyCmd.name}=get-key-cmd',
          '--${CommonArguments.signCmd.name}=sign-cmd',
        ]);

        when(
          () => codeSigner.signWithCmd(
            data: any(named: 'data'),
            command: any(named: 'command'),
          ),
        ).thenAnswer((_) async => 'bad-signature');
        when(
          () => codeSigner.runPublicKeyCmd(any()),
        ).thenAnswer((_) async => 'pem-public-key');
        when(
          () => codeSigner.verify(
            message: any(named: 'message'),
            signature: any(named: 'signature'),
            publicKeyPem: any(named: 'publicKeyPem'),
          ),
        ).thenReturn(false);

        final patcher = _TestPatcher(
          argParser: argParser,
          argResults: argResults,
          flavor: null,
          target: null,
        );

        await runScoped(
          () async {
            await expectLater(
              () => patcher.signHash('test-hash'),
              throwsA(isA<ProcessExit>()),
            );
          },
          values: {
            codeSignerRef.overrideWith(() => codeSigner),
            loggerRef.overrideWith(() => logger),
          },
        );
      });
    });
  });
}

class _TestPatcher extends Patcher {
  _TestPatcher({
    required super.argParser,
    required super.argResults,
    required super.flavor,
    required super.target,
    ReleaseType? releaseType,
  }) : _releaseType = releaseType;

  final ReleaseType? _releaseType;

  @override
  Future<void> assertPreconditions() {
    throw UnimplementedError();
  }

  @override
  Future<DiffStatus> assertUnpatchableDiffs({
    required ReleaseArtifact releaseArtifact,
    required File releaseArchive,
    required File patchArchive,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<File> buildPatchArtifact({String? releaseVersion}) {
    throw UnimplementedError();
  }

  @override
  Future<Map<Arch, PatchArtifactBundle>> createPatchArtifacts({
    required String appId,
    required int releaseId,
    required File releaseArtifact,
    Directory? supplementDirectory,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<String> extractReleaseVersionFromArtifact(File artifact) {
    throw UnimplementedError();
  }

  @override
  String get primaryReleaseArtifactArch => throw UnimplementedError();

  @override
  ReleaseType get releaseType {
    if (_releaseType != null) return _releaseType;
    throw UnimplementedError();
  }
}
