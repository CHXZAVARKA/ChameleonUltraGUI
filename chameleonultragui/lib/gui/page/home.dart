import 'package:chameleonultragui/gui/menu/dialogs/chameleon_settings.dart';
import 'package:chameleonultragui/gui/component/home_slot_grid.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:chameleonultragui/status/connected_device_status.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/main.dart';

// Localizations
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  HomePageState createState() => HomePageState();
}

class HomePageState extends State<HomePage> {
  ConnectedDeviceStatus? _status;
  StatusPresence? _homePresence;
  bool _firmwareWarningScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextStatus =
        Provider.of<ChameleonGUIState>(context).connectedDeviceStatus;
    if (identical(_status, nextStatus)) {
      return;
    }
    _status?.removeListener(_onStatusChanged);
    _homePresence?.dispose();
    _status = nextStatus;
    nextStatus?.addListener(_onStatusChanged);
    _homePresence = nextStatus?.present(StatusSurface.home);
    _scheduleFirmwareWarning();
  }

  @override
  void dispose() {
    _status?.removeListener(_onStatusChanged);
    _homePresence?.dispose();
    super.dispose();
  }

  void _onStatusChanged() {
    _scheduleFirmwareWarning();
  }

  void _scheduleFirmwareWarning() {
    if (_firmwareWarningScheduled) {
      return;
    }
    _firmwareWarningScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _firmwareWarningScheduled = false;
      if (!mounted) {
        return;
      }
      final status = _status;
      if (status == null || !status.claimFirmwareCompatibilityWarning()) {
        return;
      }
      final localizations = AppLocalizations.of(context)!;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          key: const Key('firmware-compatibility-warning'),
          title: Text(localizations.outdated_protocol),
          content: SingleChildScrollView(
            child: ListBody(
              children: [
                Text(localizations.outdated_protocol_description_1),
                Text(localizations.outdated_protocol_description_2),
                Text(localizations.outdated_protocol_description_3),
              ],
            ),
          ),
          actions: [
            TextButton(
              key: const Key('firmware-warning-update'),
              onPressed: () {
                Navigator.of(dialogContext).pop();
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) {
                    _openFirmwareDetails(context, status);
                  }
                });
              },
              child: Text(localizations.update),
            ),
            TextButton(
              key: const Key('firmware-warning-skip'),
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(localizations.skip),
            ),
          ],
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    var appState = context.read<ChameleonGUIState>();
    var localizations = AppLocalizations.of(context)!;
    final status = _status;
    if (status == null) {
      return Scaffold(appBar: AppBar(title: Text(localizations.home)));
    }
    final preferences = appState.sharedPreferencesProvider;
    return Scaffold(
      appBar: _ConnectedDeviceAppBar(
        appState: appState,
        status: status,
      ),
      body: ListenableBuilder(
        listenable: preferences,
        builder: (context, _) {
          final slotLayout = preferences.getSlotLayout();
          return LayoutBuilder(
            builder: (context, constraints) {
              final horizontalPadding =
                  constraints.maxWidth < 500 ? 12.0 : 28.0;
              final firmware = Align(
                alignment: Alignment.topCenter,
                child: _FirmwarePill(status: status),
              );
              final bottomDashboard = Center(
                child: ConstrainedBox(
                  key: const Key('home-bottom-dashboard'),
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      HomeSlotGrid(
                        status: status,
                        layout: slotLayout,
                      ),
                      const SizedBox(height: 16),
                      _HomeControls(
                        status: status,
                        preferences: preferences,
                        layout: slotLayout,
                      ),
                    ],
                  ),
                ),
              );
              final anchored = constraints.maxHeight >= 520;
              return SingleChildScrollView(
                key: const Key('home-dashboard-scroll'),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    horizontalPadding,
                    12,
                    horizontalPadding,
                    12,
                  ),
                  child: anchored
                      ? SizedBox(
                          height: constraints.maxHeight - 24,
                          child: Column(
                            children: [
                              firmware,
                              const Spacer(),
                              bottomDashboard,
                            ],
                          ),
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            firmware,
                            const SizedBox(height: 24),
                            bottomDashboard,
                          ],
                        ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _HomeControls extends StatelessWidget {
  const _HomeControls({
    required this.status,
    required this.preferences,
    required this.layout,
  });

  final ConnectedDeviceStatus status;
  final SharedPreferencesProvider preferences;
  final SlotLayout layout;

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    final layoutControl = _SlotLayoutControl(
      preferences: preferences,
      layout: layout,
    );
    Widget controls() => Row(
          key: const Key('home-controls'),
          children: [
            layoutControl,
            const SizedBox(width: 2),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: _DeviceModeControl(status: status),
              ),
            ),
            const SizedBox(width: 2),
            IconButton(
              key: const Key('home-device-settings'),
              tooltip: localizations.settings,
              onPressed: () => showDialog<String>(
                context: context,
                builder: (_) => const ChameleonSettings(),
              ),
              icon: const Icon(Icons.settings),
            ),
          ],
        );

    final textScaler = MediaQuery.textScalerOf(context);
    final baseLabelSize =
        Theme.of(context).textTheme.labelLarge?.fontSize ?? 14;
    if (textScaler.scale(baseLabelSize) <= baseLabelSize * 1.3) {
      return controls();
    }
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        key: const Key('home-controls-scroll'),
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: constraints.maxWidth),
          child: IntrinsicWidth(
            child: controls(),
          ),
        ),
      ),
    );
  }
}

class _SlotLayoutControl extends StatelessWidget {
  const _SlotLayoutControl({
    required this.preferences,
    required this.layout,
  });

  final SharedPreferencesProvider preferences;
  final SlotLayout layout;

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    final dotStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
          height: 0.72,
          fontSize: 8,
          letterSpacing: -1.2,
          fontWeight: FontWeight.w700,
        );
    return Semantics(
      key: const Key('home-slot-layout-control'),
      container: true,
      label: localizations.slot_layout,
      child: SegmentedButton<SlotLayout>(
        showSelectedIcon: false,
        segments: [
          ButtonSegment<SlotLayout>(
            value: SlotLayout.eightAcross,
            tooltip: localizations.slot_layout_eight_across,
            label: Semantics(
              label: localizations.slot_layout_eight_across,
              excludeSemantics: true,
              child: Text(
                '••••••••',
                key: const Key('home-slot-layout-eight-across'),
                style: dotStyle,
              ),
            ),
          ),
          ButtonSegment<SlotLayout>(
            value: SlotLayout.twoByFour,
            tooltip: localizations.slot_layout_two_by_four,
            label: Semantics(
              label: localizations.slot_layout_two_by_four,
              excludeSemantics: true,
              child: Text(
                '••••\n••••',
                key: const Key('home-slot-layout-two-by-four'),
                textAlign: TextAlign.center,
                style: dotStyle,
              ),
            ),
          ),
        ],
        selected: {layout},
        onSelectionChanged: (selection) {
          preferences.setSlotLayout(selection.single);
        },
        style: const ButtonStyle(
          minimumSize: WidgetStatePropertyAll(Size(48, 48)),
          fixedSize: WidgetStatePropertyAll(Size(52, 48)),
          tapTargetSize: MaterialTapTargetSize.padded,
          padding: WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 2),
          ),
        ),
      ),
    );
  }
}

Future<void> _openFirmwareDetails(
  BuildContext context,
  ConnectedDeviceStatus status,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => _FirmwareDetailsDialog(status: status),
  );
}

class _FirmwarePill extends StatelessWidget {
  const _FirmwarePill({required this.status});

  final ConnectedDeviceStatus status;

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: status,
      builder: (context, _) {
        final firmware = status.snapshot.firmware;
        final statusLabel = _firmwareStatusLabel(localizations, firmware.state);
        final semanticLabel = '${localizations.firmware} · $statusLabel · '
            '${localizations.firmware_details}';
        return Semantics(
          button: true,
          label: semanticLabel,
          excludeSemantics: true,
          onTap: () => _openFirmwareDetails(context, status),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                key: const Key('home-firmware-pill'),
                excludeFromSemantics: true,
                customBorder: const StadiumBorder(),
                onTap: () => _openFirmwareDetails(context, status),
                child: Center(
                  widthFactor: 1,
                  child: Ink(
                    key: const Key('firmware-visual-pill'),
                    decoration: BoxDecoration(
                      color:
                          Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      child: Wrap(
                        alignment: WrapAlignment.center,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            localizations.firmware,
                            key: const Key('firmware-label'),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurface,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Text(' • '),
                          Text(
                            statusLabel,
                            key: const Key('firmware-status-text'),
                            style: TextStyle(
                              color: _firmwareStatusColor(
                                context,
                                firmware.state,
                              ),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _FirmwareDetailsDialog extends StatelessWidget {
  const _FirmwareDetailsDialog({required this.status});

  final ConnectedDeviceStatus status;

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: status,
      builder: (context, _) {
        final snapshot = status.snapshot;
        final firmware = snapshot.firmware;
        final latest = _latestFirmwareLabel(localizations, firmware);
        return AlertDialog(
          key: const Key('firmware-details-dialog'),
          title: Text(localizations.firmware_details),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _FirmwareDetailRow(
                  label: localizations.model,
                  value: chameleonDeviceName(snapshot.identity.device),
                ),
                _FirmwareDetailRow(
                  label: localizations.installed_version,
                  value: firmware.installedVersion ?? localizations.unknown,
                ),
                _FirmwareDetailRow(
                  label: localizations.installed_commit,
                  value: firmware.installedCommit ?? localizations.unknown,
                ),
                _FirmwareDetailRow(
                  label: localizations.protocol,
                  value: _firmwareProtocolLabel(
                    localizations,
                    firmware.protocol,
                  ),
                ),
                _FirmwareDetailRow(
                  label: localizations.latest_version_or_commit,
                  value: latest,
                ),
                _FirmwareDetailRow(
                  label: localizations.last_check_result,
                  value: _firmwareCheckResultLabel(localizations, firmware),
                ),
                if (firmware.installationFailed)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      localizations.update_error,
                      key: const Key('firmware-update-error'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            if (firmware.checkResult == FirmwareCheckResult.unavailable)
              TextButton(
                key: const Key('firmware-check-retry'),
                onPressed: firmware.installing
                    ? null
                    : () => status.retryFirmwareCheck(),
                child: Text(localizations.retry),
              ),
            if (firmware.canInstall)
              FilledButton(
                key: Key(
                  firmware.installationFailed
                      ? 'firmware-install-retry'
                      : 'firmware-update',
                ),
                onPressed: firmware.installing
                    ? null
                    : () async {
                        final outcome = await status.installFirmware();
                        if (context.mounted &&
                            (outcome == FirmwareInstallOutcome.started ||
                                outcome ==
                                    FirmwareInstallOutcome.connectionChanged)) {
                          Navigator.of(context).pop();
                        }
                      },
                child: firmware.installing
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        firmware.installationFailed
                            ? localizations.retry
                            : localizations.update,
                      ),
              ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(localizations.close),
            ),
          ],
        );
      },
    );
  }
}

class _FirmwareDetailRow extends StatelessWidget {
  const _FirmwareDetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            TextSpan(text: value),
          ],
        ),
      ),
    );
  }
}

String _firmwareStatusLabel(
  AppLocalizations localizations,
  FirmwareState state,
) =>
    switch (state) {
      FirmwareState.checking => localizations.firmware_checking,
      FirmwareState.upToDate => localizations.firmware_up_to_date,
      FirmwareState.updateAvailable => localizations.firmware_update_available,
      FirmwareState.updateRequired => localizations.firmware_update_required,
      FirmwareState.checkUnavailable =>
        localizations.firmware_check_unavailable,
      FirmwareState.demo => localizations.firmware_demo,
    };

String _firmwareProtocolLabel(
  AppLocalizations localizations,
  FirmwareProtocol protocol,
) =>
    switch (protocol) {
      FirmwareProtocol.loading => localizations.firmware_checking,
      FirmwareProtocol.current => localizations.current_protocol,
      FirmwareProtocol.legacy => localizations.legacy_protocol,
      FirmwareProtocol.unknown => localizations.unknown,
    };

String _latestFirmwareLabel(
  AppLocalizations localizations,
  FirmwareStatus firmware,
) {
  final version = firmware.latestVersion;
  final commit = firmware.latestCommit;
  if (version != null && commit != null) {
    return '$version ($commit)';
  }
  return version ?? commit ?? localizations.unknown;
}

String _firmwareCheckResultLabel(
  AppLocalizations localizations,
  FirmwareStatus firmware,
) =>
    switch (firmware.checkResult) {
      FirmwareCheckResult.checking => localizations.firmware_checking,
      FirmwareCheckResult.succeeded =>
        _firmwareStatusLabel(localizations, firmware.state),
      FirmwareCheckResult.unavailable =>
        localizations.firmware_check_unavailable,
      FirmwareCheckResult.demo => localizations.firmware_demo,
    };

Color _firmwareStatusColor(BuildContext context, FirmwareState state) {
  final theme = Theme.of(context);
  final dark = theme.brightness == Brightness.dark;
  return switch (state) {
    FirmwareState.upToDate =>
      dark ? Colors.green.shade300 : Colors.green.shade700,
    FirmwareState.updateAvailable =>
      dark ? Colors.amber.shade300 : Colors.amber.shade800,
    FirmwareState.updateRequired => theme.colorScheme.error,
    FirmwareState.checkUnavailable =>
      dark ? Colors.grey.shade400 : Colors.grey.shade600,
    FirmwareState.checking ||
    FirmwareState.demo =>
      theme.colorScheme.onSurfaceVariant,
  };
}

class _DeviceModeControl extends StatelessWidget {
  const _DeviceModeControl({required this.status});

  final ConnectedDeviceStatus status;

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    return SizedBox(
      key: const Key('home-mode-control'),
      child: ListenableBuilder(
        listenable: status,
        builder: (context, _) {
          final mode = status.snapshot.mode;
          final isLite =
              status.snapshot.identity.device == ChameleonDevice.lite;
          final enabled = mode.availability == ModeAvailability.available &&
              mode.pendingMode == null;
          final control = SegmentedButton<ConnectedDeviceMode>(
            segments: [
              ButtonSegment(
                value: ConnectedDeviceMode.emulator,
                label: Text(localizations.emulator),
              ),
              ButtonSegment(
                value: ConnectedDeviceMode.reader,
                enabled: !isLite,
                tooltip: isLite ? localizations.lite_no_read : null,
                label: Text(localizations.reader),
              ),
            ],
            selected:
                mode.confirmedMode == null ? const {} : {mode.confirmedMode!},
            emptySelectionAllowed: mode.confirmedMode == null,
            onSelectionChanged: enabled
                ? (selection) async {
                    final outcome = await status.switchMode(selection.single);
                    if (outcome == ModeActionOutcome.failed &&
                        context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            '${localizations.error}: ${localizations.unavailable}',
                          ),
                        ),
                      );
                    }
                  }
                : null,
            style: const ButtonStyle(
              minimumSize: WidgetStatePropertyAll(Size(48, 48)),
              tapTargetSize: MaterialTapTargetSize.padded,
              padding: WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
          );
          if (mode.availability != ModeAvailability.unavailable) {
            return control;
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              control,
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  key: const Key('home-mode-retry'),
                  tooltip: localizations.unavailable,
                  onPressed: status.refreshMode,
                  icon: const Icon(Icons.refresh),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ConnectedDeviceAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  const _ConnectedDeviceAppBar({
    required this.appState,
    required this.status,
  });

  final ChameleonGUIState appState;
  final ConnectedDeviceStatus status;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: status,
      builder: (context, _) {
        final snapshot = status.snapshot;
        final identity = snapshot.identity;
        final connectionLabel =
            '${localizations.chameleon_connected}: ${identity.connectionType == ConnectionType.ble ? 'Bluetooth' : 'USB'}';
        final disconnectLabel =
            '${localizations.deactivate} · $connectionLabel';
        return AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Chameleon ${chameleonDeviceName(identity.device)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                identity.portName,
                key: const Key('home-device-port'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            Tooltip(
              message: connectionLabel,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Icon(
                  identity.connectionType == ConnectionType.ble
                      ? Icons.bluetooth
                      : Icons.usb,
                ),
              ),
            ),
            _BatteryIndicator(battery: snapshot.battery),
            Semantics(
              label: disconnectLabel,
              button: true,
              child: IconButton(
                tooltip: disconnectLabel,
                onPressed: () => appState.disconnect(manual: true),
                icon: const Icon(Icons.link_off),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _BatteryIndicator extends StatelessWidget {
  const _BatteryIndicator({required this.battery});

  final BatteryStatus battery;

  @override
  Widget build(BuildContext context) {
    final percent = battery.percent;
    final color = _batteryColor(context, percent);
    final percentLabel = percent == null ? '--%' : '$percent%';
    final voltage = battery.voltageMillivolts;
    final tooltip = voltage == null
        ? percentLabel
        : '$percentLabel · ${(voltage / 1000).toStringAsFixed(2)} V';

    return Tooltip(
      message: tooltip,
      child: Semantics(
        label: tooltip,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_batteryIcon(percent), color: color),
              const SizedBox(width: 4),
              Text(percentLabel, style: TextStyle(color: color)),
            ],
          ),
        ),
      ),
    );
  }

  Color _batteryColor(BuildContext context, int? percent) {
    final colors = Theme.of(context).colorScheme;
    if (percent == null) {
      return colors.onSurfaceVariant;
    }
    if (percent <= 10) {
      return colors.error;
    }
    if (percent <= 20) {
      return Colors.amber.shade700;
    }
    return colors.onSurface;
  }

  IconData _batteryIcon(int? percent) {
    if (percent == null) return Icons.battery_unknown;
    if (percent > 98) return Icons.battery_full;
    if (percent > 87) return Icons.battery_6_bar;
    if (percent > 75) return Icons.battery_5_bar;
    if (percent > 62) return Icons.battery_4_bar;
    if (percent > 50) return Icons.battery_3_bar;
    if (percent > 37) return Icons.battery_2_bar;
    if (percent > 10) return Icons.battery_1_bar;
    if (percent > 3) return Icons.battery_0_bar;
    return Icons.battery_alert;
  }
}
