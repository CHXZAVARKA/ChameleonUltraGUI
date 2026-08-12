import 'dart:convert';
import 'dart:typed_data';

import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/helpers/flash.dart';
import 'package:chameleonultragui/helpers/github.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:chameleonultragui/status/firmware_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('firmware channel preference', () {
    test('defaults to Official and persists an explicit Custom choice',
        () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = SharedPreferencesProvider();
      await preferences.load();

      expect(preferences.getFirmwareChannel(), FirmwareChannel.official);

      preferences.setFirmwareChannel(FirmwareChannel.custom);
      expect(preferences.getFirmwareChannel(), FirmwareChannel.custom);

      await preferences.load();
      expect(preferences.getFirmwareChannel(), FirmwareChannel.custom);
    });

    test('maps channels to the expected GitHub repositories', () {
      expect(
        FirmwareChannel.official.repository,
        'RfidResearchGroup/ChameleonUltra',
      );
      expect(
        FirmwareChannel.custom.repository,
        'CHXZAVARKA/ChameleonUltra',
      );
      expect(FirmwareChannel.official.usesActionsArtifacts, isTrue);
      expect(FirmwareChannel.custom.usesActionsArtifacts, isFalse);
    });
  });

  group('firmwareUpdateAvailable', () {
    test('returns unknown when the installed commit is empty', () {
      expect(
        firmwareUpdateAvailable(
          installedCommit: '',
          latestCommit: 'abcdef1234567890',
        ),
        isNull,
      );
      expect(
        firmwareUpdateAvailable(
          installedCommit: '   ',
          latestCommit: 'abcdef1234567890',
        ),
        isNull,
      );
    });

    test('treats short and full forms of the same SHA as current', () {
      expect(
        firmwareUpdateAvailable(
          installedCommit: 'ABCDEF1',
          latestCommit: 'abcdef1234567890',
        ),
        isFalse,
      );
      expect(
        firmwareUpdateAvailable(
          installedCommit: 'abcdef1234567890',
          latestCommit: 'abcdef1',
        ),
        isFalse,
      );
    });

    test('reports a different SHA as an available update', () {
      expect(
        firmwareUpdateAvailable(
          installedCommit: 'abcdef1',
          latestCommit: '1234567890abcdef',
        ),
        isTrue,
      );
    });
  });

  group('GitHubFirmwareCatalog', () {
    test('uses the selected channel for release and commit lookup', () async {
      FirmwareChannel? releaseChannel;
      FirmwareChannel? resolutionChannel;
      final catalog = GitHubFirmwareCatalog(
        latestCommitLoader: (_, channel) async {
          releaseChannel = channel;
          return 'abcdef1234567890';
        },
        commitResolver: (commit, channel) async {
          resolutionChannel = channel;
          return commit;
        },
      );

      await catalog.latestFirmware(
        device: ChameleonDevice.ultra,
        installedCommit: 'abcdef1',
        channel: FirmwareChannel.custom,
      );

      expect(releaseChannel, FirmwareChannel.custom);
      expect(resolutionChannel, FirmwareChannel.custom);
    });

    test('uses injected GitHub helpers without network access', () async {
      final catalog = GitHubFirmwareCatalog(
        latestCommitLoader: (_, __) async => 'abcdef1234567890',
        commitResolver: (commit, _) async => 'abcdef1234567890',
      );

      final release = await catalog.latestFirmware(
        device: ChameleonDevice.ultra,
        installedCommit: 'abcdef1',
      );

      expect(release.latestCommit, 'abcdef1234567890');
      expect(release.updateAvailable, isFalse);
    });

    test('propagates latest-commit lookup errors', () async {
      final failure = StateError('lookup failed');
      final catalog = GitHubFirmwareCatalog(
        latestCommitLoader: (_, __) async => throw failure,
      );

      await expectLater(
        catalog.latestFirmware(
          device: ChameleonDevice.ultra,
          installedCommit: 'abcdef1',
        ),
        throwsA(same(failure)),
      );
    });

    test('propagates installed-commit resolution errors', () async {
      final failure = StateError('resolution failed');
      final catalog = GitHubFirmwareCatalog(
        latestCommitLoader: (_, __) async => 'abcdef1234567890',
        commitResolver: (_, __) async => throw failure,
      );

      await expectLater(
        catalog.latestFirmware(
          device: ChameleonDevice.ultra,
          installedCommit: 'abcdef1',
        ),
        throwsA(same(failure)),
      );
    });
  });

  group('firmware download channel', () {
    test('all flash surfaces inherit Custom unless they override the channel',
        () async {
      SharedPreferences.setMockInitialValues({
        'firmware_channel': FirmwareChannel.custom.name,
      });
      final preferences = SharedPreferencesProvider();
      await preferences.load();

      expect(
        resolveFirmwareChannel(preferences),
        FirmwareChannel.custom,
      );
      expect(
        resolveFirmwareChannel(preferences, FirmwareChannel.official),
        FirmwareChannel.official,
      );
    });

    test('selects the newest eligible release by publication time', () {
      final release = selectLatestFirmwareRelease(
        [
          _release(
            'missing-date-commit',
            null,
            assets: [_ultraAsset('missing-date')],
          ),
          _release(
            'malformed-date-commit',
            'not-a-date',
            assets: [_ultraAsset('malformed-date')],
          ),
          _release('old-commit', '2026-08-01', assets: [_ultraAsset('old')]),
          _release(
            'manual-commit',
            '2026-08-03',
            author: 'release-maintainer',
            assets: [_ultraAsset('manual')],
          ),
          _release('new-commit', '2026-08-02', assets: [_ultraAsset('new')]),
        ],
        ChameleonDevice.ultra,
      );

      expect(release?.commit, 'new-commit');
      expect(
        release?.applicationArchiveFor(ChameleonDevice.ultra),
        Uri.parse('https://example.test/new-ultra.zip'),
      );

      final undatedRelease = selectLatestFirmwareRelease(
        [
          _release('first-commit', null, assets: [_ultraAsset('first')]),
          _release('second-commit', null, assets: [_ultraAsset('second')]),
        ],
        ChameleonDevice.ultra,
      );
      expect(undatedRelease?.commit, 'first-commit');
    });

    test('metadata and download share eligibility and exact-model assets',
        () async {
      final releasePayload = jsonEncode([
        _release(
          'unrelated-commit',
          '2026-08-05',
          assets: [_asset('debug-symbols.zip', 'debug-symbols.zip')],
        ),
        _release(
          'manual-commit',
          '2026-08-04',
          author: 'release-maintainer',
          assets: [_ultraAsset('manual')],
        ),
        _release(
          'selected-commit',
          '2026-08-03',
          assets: [
            _liteAsset('selected'),
            _asset('unrelated.zip', 'unrelated.zip'),
            _ultraAsset('selected'),
          ],
        ),
        _release(
          'stable-commit',
          '2026-08-02',
          prerelease: false,
          assets: [_ultraAsset('stable')],
        ),
        _release('old-commit', '2026-08-01', assets: [_ultraAsset('old')]),
      ]);
      final requestedAssets = <Uri>[];
      final requestedApiUrls = <Uri>[];
      final client = MockClient((request) async {
        if (request.url.host == 'api.github.com') {
          requestedApiUrls.add(request.url);
          return http.Response(releasePayload, 200);
        }
        requestedAssets.add(request.url);
        return switch (request.url.path) {
          '/selected-ultra.zip' => http.Response.bytes([1, 2, 3], 200),
          '/selected-lite.zip' => http.Response.bytes([4, 5, 6], 200),
          _ => http.Response('not found', 404),
        };
      });

      await http.runWithClient(() async {
        expect(
          await latestAvailableCommit(
            ChameleonDevice.ultra,
            FirmwareChannel.custom,
          ),
          'selected-commit',
        );
        expect(
          await fetchFirmwareFromReleases(
            ChameleonDevice.ultra,
            FirmwareChannel.custom,
          ),
          Uint8List.fromList([1, 2, 3]),
        );
        expect(
          await fetchFirmwareFromReleases(
            ChameleonDevice.lite,
            FirmwareChannel.custom,
          ),
          Uint8List.fromList([4, 5, 6]),
        );
      }, () => client);

      expect(
        requestedApiUrls,
        List.filled(
          3,
          Uri.parse(
            'https://api.github.com/repos/CHXZAVARKA/ChameleonUltra/releases',
          ),
        ),
      );
      expect(
        requestedAssets,
        [
          Uri.parse('https://example.test/selected-ultra.zip'),
          Uri.parse('https://example.test/selected-lite.zip'),
        ],
      );
    });

    test('Official metadata prefers Actions and falls back to releases',
        () async {
      var actionsRequests = 0;
      final requestedUrls = <Uri>[];
      final client = MockClient((request) async {
        requestedUrls.add(request.url);
        if (request.url.path.endsWith('/actions/artifacts')) {
          actionsRequests++;
          return http.Response(
            jsonEncode({
              'artifacts': actionsRequests == 1
                  ? [
                      {
                        'name': 'ultra-dfu-app',
                        'workflow_run': {
                          'head_branch': 'main',
                          'head_repository_id': 581338100,
                          'head_sha': 'actions-commit',
                        },
                      },
                    ]
                  : [],
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/releases')) {
          return http.Response(
            jsonEncode([
              _release(
                'release-commit',
                '2026-08-03',
                assets: [_ultraAsset('release')],
              ),
            ]),
            200,
          );
        }
        return http.Response('not found', 404);
      });

      await http.runWithClient(() async {
        expect(
          await latestAvailableCommit(ChameleonDevice.ultra),
          'actions-commit',
        );
        expect(
          await latestAvailableCommit(ChameleonDevice.ultra),
          'release-commit',
        );
      }, () => client);

      expect(
        requestedUrls,
        [
          Uri.parse(
            'https://api.github.com/repos/RfidResearchGroup/ChameleonUltra/actions/artifacts?per_page=100',
          ),
          Uri.parse(
            'https://api.github.com/repos/RfidResearchGroup/ChameleonUltra/actions/artifacts?per_page=100',
          ),
          Uri.parse(
            'https://api.github.com/repos/RfidResearchGroup/ChameleonUltra/releases',
          ),
        ],
      );
    });

    test('release API errors stay visible while download failures stay empty',
        () async {
      final apiErrorClient = MockClient(
        (_) async =>
            http.Response(jsonEncode({'message': 'rate limited'}), 403),
      );

      await http.runWithClient(() async {
        await expectLater(
          latestAvailableCommit(
            ChameleonDevice.ultra,
            FirmwareChannel.custom,
          ),
          throwsA('rate limited'),
        );
        await expectLater(
          fetchFirmwareFromReleases(
            ChameleonDevice.ultra,
            FirmwareChannel.custom,
          ),
          throwsA('rate limited'),
        );
      }, () => apiErrorClient);

      final downloadFailureClient = MockClient((request) async {
        if (request.url.host == 'api.github.com') {
          return http.Response(
            jsonEncode([
              _release(
                'selected-commit',
                '2026-08-03',
                assets: [_ultraAsset('selected')],
              ),
            ]),
            200,
          );
        }
        throw StateError('download failed');
      });

      await http.runWithClient(() async {
        expect(
          await fetchFirmwareFromReleases(
            ChameleonDevice.ultra,
            FirmwareChannel.custom,
          ),
          isEmpty,
        );
      }, () => downloadFailureClient);
    });

    test('Custom downloads the model-specific release without Actions',
        () async {
      var actionCalls = 0;
      var releaseCalls = 0;
      ChameleonDevice? requestedDevice;
      FirmwareChannel? requestedChannel;
      final archive = Uint8List.fromList([1, 2, 3]);

      final result = await fetchFirmware(
        ChameleonDevice.lite,
        channel: FirmwareChannel.custom,
        actionsLoader: (device, channel) async {
          actionCalls++;
          return Uint8List(0);
        },
        releasesLoader: (device, channel) async {
          releaseCalls++;
          requestedDevice = device;
          requestedChannel = channel;
          return archive;
        },
      );

      expect(result, archive);
      expect(actionCalls, 0);
      expect(releaseCalls, 1);
      expect(requestedDevice, ChameleonDevice.lite);
      expect(requestedChannel, FirmwareChannel.custom);
    });

    test('Official downloads Actions without querying releases', () async {
      var actionCalls = 0;
      var releaseCalls = 0;

      final result = await fetchFirmware(
        ChameleonDevice.ultra,
        actionsLoader: (_, __) async {
          actionCalls++;
          return Uint8List.fromList([1, 2, 3]);
        },
        releasesLoader: (_, __) async {
          releaseCalls++;
          return Uint8List.fromList([4, 5, 6]);
        },
      );

      expect(result, Uint8List.fromList([1, 2, 3]));
      expect(actionCalls, 1);
      expect(releaseCalls, 0);
    });
  });
}

Map<String, Object?> _release(
  String commit,
  String? date, {
  String author = 'github-actions[bot]',
  bool prerelease = true,
  List<Map<String, String>> assets = const [],
}) =>
    {
      'author': {'login': author},
      'prerelease': prerelease,
      if (date != null)
        'published_at': date.contains('T') ? date : '${date}T12:00:00Z',
      'target_commitish': commit,
      'assets': assets,
    };

Map<String, String> _asset(String name, String path) => {
      'name': name,
      'browser_download_url': 'https://example.test/$path',
    };

Map<String, String> _ultraAsset(String release) =>
    _asset('ultra-dfu-app.zip', '$release-ultra.zip');

Map<String, String> _liteAsset(String release) =>
    _asset('lite-dfu-app.zip', '$release-lite.zip');
