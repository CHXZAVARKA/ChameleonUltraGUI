import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/helpers/mifare_classic/maintenance.dart';

class MifareClassicMaintenanceProgressPresenter {
  const MifareClassicMaintenanceProgressPresenter(
    this.progress,
    this.localizations,
  );

  final MifareClassicMaintenanceProgress progress;
  final AppLocalizations localizations;

  String get phaseLabel => switch (progress.phase) {
        MifareClassicMaintenancePhase.preflight =>
          localizations.mifare_classic_standard_phase_preflight,
        MifareClassicMaintenancePhase.revalidating =>
          localizations.mifare_classic_standard_phase_revalidating,
        MifareClassicMaintenancePhase.writing =>
          localizations.mifare_classic_standard_phase_writing,
        MifareClassicMaintenancePhase.verifying =>
          localizations.mifare_classic_standard_phase_verifying,
      };

  String get label => localizations.mifare_classic_standard_progress(
        phaseLabel,
        progress.completed,
        progress.total,
      );

  double? get fraction {
    if (progress.total == 0) {
      return null;
    }
    return (progress.completed / progress.total).clamp(0.0, 1.0);
  }
}
