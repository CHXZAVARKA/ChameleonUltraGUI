import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/status/firmware_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
    test('uses injected GitHub helpers without network access', () async {
      final catalog = GitHubFirmwareCatalog(
        latestCommitLoader: (_) async => 'abcdef1234567890',
        commitResolver: (commit) async => 'abcdef1234567890',
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
        latestCommitLoader: (_) async => throw failure,
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
        latestCommitLoader: (_) async => 'abcdef1234567890',
        commitResolver: (_) async => throw failure,
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
}
