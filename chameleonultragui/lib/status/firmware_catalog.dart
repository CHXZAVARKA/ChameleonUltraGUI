import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/helpers/github.dart';
import 'package:flutter/foundation.dart';

@immutable
class FirmwareCatalogRelease {
  const FirmwareCatalogRelease({
    this.latestVersion,
    required this.latestCommit,
    required this.updateAvailable,
  });

  final String? latestVersion;
  final String latestCommit;
  final bool? updateAvailable;
}

abstract interface class FirmwareCatalog {
  Future<FirmwareCatalogRelease> latestFirmware({
    required ChameleonDevice device,
    required String? installedCommit,
  });
}

typedef LatestFirmwareCommitLoader = Future<String> Function(
  ChameleonDevice device,
);
typedef FirmwareCommitResolver = Future<String> Function(String commit);

class GitHubFirmwareCatalog implements FirmwareCatalog {
  const GitHubFirmwareCatalog({
    this.latestCommitLoader = latestAvailableCommit,
    this.commitResolver = resolveCommit,
  });

  final LatestFirmwareCommitLoader latestCommitLoader;
  final FirmwareCommitResolver commitResolver;

  @override
  Future<FirmwareCatalogRelease> latestFirmware({
    required ChameleonDevice device,
    required String? installedCommit,
  }) async {
    final latestCommit = await latestCommitLoader(device);
    if (latestCommit.isEmpty) {
      throw StateError('No firmware release is available');
    }

    String? normalizedInstalledCommit;
    if (installedCommit != null && installedCommit.isNotEmpty) {
      normalizedInstalledCommit = await commitResolver(installedCommit);
    }

    return FirmwareCatalogRelease(
      latestCommit: latestCommit,
      updateAvailable: firmwareUpdateAvailable(
        installedCommit: normalizedInstalledCommit,
        latestCommit: latestCommit,
      ),
    );
  }
}

bool? firmwareUpdateAvailable({
  required String? installedCommit,
  required String latestCommit,
}) {
  final installed = installedCommit?.trim().toLowerCase() ?? '';
  final latest = latestCommit.trim().toLowerCase();
  if (installed.isEmpty || latest.isEmpty) {
    return null;
  }
  return !(latest.startsWith(installed) || installed.startsWith(latest));
}
