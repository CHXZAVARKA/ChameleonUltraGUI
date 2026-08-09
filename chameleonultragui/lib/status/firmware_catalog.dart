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

class GitHubFirmwareCatalog implements FirmwareCatalog {
  const GitHubFirmwareCatalog();

  @override
  Future<FirmwareCatalogRelease> latestFirmware({
    required ChameleonDevice device,
    required String? installedCommit,
  }) async {
    final latestCommit = await latestAvailableCommit(device);
    if (latestCommit.isEmpty) {
      throw StateError('No firmware release is available');
    }

    String? normalizedInstalledCommit;
    if (installedCommit != null && installedCommit.isNotEmpty) {
      normalizedInstalledCommit = await resolveCommit(installedCommit);
    }

    return FirmwareCatalogRelease(
      latestCommit: latestCommit,
      updateAvailable:
          normalizedInstalledCommit == null || normalizedInstalledCommit.isEmpty
              ? null
              : !latestCommit.startsWith(normalizedInstalledCommit),
    );
  }
}
