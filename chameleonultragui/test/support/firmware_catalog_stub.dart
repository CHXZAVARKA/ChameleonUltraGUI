import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/status/firmware_catalog.dart';

class CurrentFirmwareCatalogStub implements FirmwareCatalog {
  const CurrentFirmwareCatalogStub();

  @override
  Future<FirmwareCatalogRelease> latestFirmware({
    required ChameleonDevice device,
    required String? installedCommit,
  }) async =>
      FirmwareCatalogRelease(
        latestCommit: installedCommit ?? 'current',
        updateAvailable: false,
      );
}
