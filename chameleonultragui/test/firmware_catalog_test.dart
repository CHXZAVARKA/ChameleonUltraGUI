import 'dart:typed_data';

import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/helpers/flash.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:chameleonultragui/status/firmware_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
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
  });
}
