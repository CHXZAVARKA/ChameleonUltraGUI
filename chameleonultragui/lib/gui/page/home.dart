import 'package:chameleonultragui/gui/menu/dialogs/chameleon_settings.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/flash.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/github.dart';
import 'package:chameleonultragui/status/connected_device_status.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/gui/component/slot_changer.dart';
import 'dart:math';

// Localizations
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  HomePageState createState() => HomePageState();
}

class HomePageState extends State<HomePage> {
  int selectedSlot = 1;
  bool isLegacyFirmware = false;
  ConnectedDeviceStatus? _status;
  StatusPresence? _homePresence;

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextStatus =
        Provider.of<ChameleonGUIState>(context).connectedDeviceStatus;
    if (identical(_status, nextStatus)) {
      return;
    }
    _homePresence?.dispose();
    _status = nextStatus;
    _homePresence = nextStatus?.present(StatusSurface.home);
  }

  @override
  void dispose() {
    _homePresence?.dispose();
    super.dispose();
  }

  Future<(String, List<String>, bool, bool)> getFutureData() async {
    var appState = context.read<ChameleonGUIState>();
    List<SlotTypes> slotTypes = [];
    try {
      slotTypes = await appState.communicator!.getSlotTagTypes();
    } catch (e) {
      appState.log!.e(e);
    }

    return (
      await getUsedSlotsOut8(slotTypes),
      await getVersion(),
      await isReaderDeviceMode(),
      await areCapabilitiesSupported()
    );
  }

  Future<bool> areCapabilitiesSupported() async {
    // Checks that firmware supports all functions of current app
    // If not, prompt user to update firmware (as outdated firmware might break app)

    int ultraCapability = ChameleonCommand.setIdteckEmulatorID.value;
    int liteCapability = ChameleonCommand.setIdteckEmulatorID.value;

    var appState = context.read<ChameleonGUIState>();
    List<int> capabilities;
    try {
      capabilities = await appState.communicator!.getDeviceCapabilities();
    } catch (_) {
      return false;
    }

    if (appState.connector!.device == ChameleonDevice.ultra &&
        !capabilities.contains(ultraCapability)) {
      return false;
    }

    if (appState.connector!.device == ChameleonDevice.lite &&
        !capabilities.contains(liteCapability)) {
      return false;
    }

    return true;
  }

  Future<String> getUsedSlotsOut8(List<SlotTypes> slotTypes) async {
    int usedSlotsOut8 = 0;

    if (slotTypes.isEmpty) {
      return AppLocalizations.of(context)!.unknown;
    }

    for (int i = 0; i < 8; i++) {
      if (slotTypes[i].notMatch()) {
        usedSlotsOut8++;
      }
    }
    return usedSlotsOut8.toString();
  }

  Future<List<String>> getVersion() async {
    var appState = context.read<ChameleonGUIState>();

    String commitHash = "";
    var firmware = await appState.communicator!.getFirmwareVersion();
    isLegacyFirmware = firmware.legacyProtocol;
    String firmwareVersion = numToVerCode(firmware.version);

    try {
      commitHash = await appState.communicator!.getGitCommitHash();
    } catch (_) {}

    if (commitHash.isEmpty) {
      if (mounted) {
        commitHash = AppLocalizations.of(context)!.outdated_fw;
      } else {
        commitHash = "Outdated FW";
      }
    }

    if (mounted && isLegacyFirmware) {
      var localizations = AppLocalizations.of(context)!;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) {
          return AlertDialog(
            title: Text(localizations.outdated_protocol),
            content: SingleChildScrollView(
              child: ListBody(
                children: <Widget>[
                  Text(localizations.outdated_protocol_description_1),
                  Text(localizations.outdated_protocol_description_2),
                  Text(localizations.outdated_protocol_description_3),
                ],
              ),
            ),
            actions: <Widget>[
              TextButton(
                child: Text(localizations.update),
                onPressed: () async {
                  Navigator.of(context).pop();
                  var localizations = AppLocalizations.of(context)!;
                  var scaffoldMessenger = ScaffoldMessenger.of(context);
                  var snackBar = SnackBar(
                    content: Text(localizations.downloading_fw(
                        chameleonDeviceName(appState.connector!.device))),
                    action: SnackBarAction(
                      label: localizations.close,
                      onPressed: () {
                        scaffoldMessenger.hideCurrentSnackBar();
                      },
                    ),
                  );

                  scaffoldMessenger.showSnackBar(snackBar);
                  await flashFirmware(appState,
                      scaffoldMessenger: scaffoldMessenger);
                },
              ),
              TextButton(
                child: Text(localizations.skip),
                onPressed: () {
                  Navigator.of(context).pop();
                },
              ),
            ],
          );
        },
      );
    }

    return ["$firmwareVersion ($commitHash)", commitHash];
  }

  Future<bool> isReaderDeviceMode() async {
    var appState = context.read<ChameleonGUIState>();
    return await appState.communicator!.isReaderDeviceMode();
  }

  @override
  Widget build(BuildContext context) {
    var appState = context.read<ChameleonGUIState>();
    var localizations = AppLocalizations.of(context)!;
    var scaffoldMessenger = ScaffoldMessenger.of(context);
    final status = _status;
    if (status == null) {
      return Scaffold(appBar: AppBar(title: Text(localizations.home)));
    }
    return Scaffold(
      appBar: _ConnectedDeviceAppBar(
        appState: appState,
        status: status,
      ),
      body: FutureBuilder(
        future: getFutureData(),
        builder: (BuildContext context, AsyncSnapshot snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return _LegacyHomePlaceholder(
              device: status.snapshot.identity.device,
            );
          } else if (snapshot.hasError) {
            return _LegacyHomePlaceholder(
              device: status.snapshot.identity.device,
              errorMessage: snapshot.error.toString(),
            );
          } else {
            final (
              usedSlots,
              fwVersion,
              isReaderDeviceMode,
              areCapabilitiesSupported,
            ) = snapshot.data;

            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(height: 20),
                  Text("${localizations.used_slots}: $usedSlots/8",
                      style: TextStyle(
                        fontSize: min(
                          MediaQuery.of(context).size.width / 35,
                          MediaQuery.of(context).size.height / 20,
                        ),
                      )),
                  const FittedBox(
                      alignment: Alignment.center,
                      fit: BoxFit.scaleDown,
                      child: SlotChanger()),
                  Expanded(
                    child: FractionallySizedBox(
                      widthFactor: 0.4,
                      child: Image.asset(
                        appState.connector!.device == ChameleonDevice.ultra
                            ? 'assets/black-ultra-standing-front.webp'
                            : 'assets/black-lite-standing-front.webp',
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (appState.connector!.portName != "Demo")
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text("${localizations.firmware_version}: ",
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: min(
                                MediaQuery.of(context).size.width / 50,
                                MediaQuery.of(context).size.height / 30,
                              ),
                            )),
                        Text(fwVersion[0],
                            style: TextStyle(
                              fontSize: min(
                                MediaQuery.of(context).size.width / 50,
                                MediaQuery.of(context).size.height / 30,
                              ),
                            )),
                        Padding(
                          padding: const EdgeInsets.all(4.0),
                          child: IconButton(
                            onPressed: () async {
                              SnackBar snackBar;
                              String latestCommit;

                              try {
                                latestCommit = await latestAvailableCommit(
                                    appState.connector!.device);
                              } catch (e) {
                                if (context.mounted) {
                                  scaffoldMessenger.hideCurrentSnackBar();
                                  snackBar = SnackBar(
                                    content: Text(
                                        '${localizations.update_error}: ${e.toString()}'),
                                    action: SnackBarAction(
                                      label: localizations.close,
                                      onPressed: () {},
                                    ),
                                  );

                                  scaffoldMessenger.showSnackBar(snackBar);
                                }
                                return;
                              }

                              try {
                                fwVersion[1] =
                                    await resolveCommit(fwVersion[1]);
                              } catch (_) {}

                              appState.log!.i(
                                  "Latest commit: $latestCommit, current commit ${fwVersion[1]}");

                              if (latestCommit.isEmpty) {
                                return;
                              }

                              if (latestCommit.startsWith(fwVersion[1]) &&
                                  context.mounted) {
                                snackBar = SnackBar(
                                  content: Text(localizations.up_to_date(
                                      chameleonDeviceName(
                                          appState.connector!.device))),
                                  action: SnackBarAction(
                                    label: localizations.close,
                                    onPressed: () {},
                                  ),
                                );

                                scaffoldMessenger.showSnackBar(snackBar);
                              } else if (context.mounted) {
                                snackBar = SnackBar(
                                  content: Text(localizations.downloading_fw(
                                      chameleonDeviceName(
                                          appState.connector!.device))),
                                  action: SnackBarAction(
                                    label: localizations.close,
                                    onPressed: () {
                                      scaffoldMessenger.hideCurrentSnackBar();
                                    },
                                  ),
                                );

                                scaffoldMessenger.showSnackBar(snackBar);
                                try {
                                  await flashFirmware(appState,
                                      scaffoldMessenger: scaffoldMessenger);
                                } catch (e) {
                                  if (context.mounted) {
                                    scaffoldMessenger.hideCurrentSnackBar();
                                    snackBar = SnackBar(
                                      content: Text(
                                          '${localizations.update_error}: ${e.toString()}'),
                                      action: SnackBarAction(
                                        label: localizations.close,
                                        onPressed: () {
                                          scaffoldMessenger
                                              .hideCurrentSnackBar();
                                        },
                                      ),
                                    );

                                    scaffoldMessenger.showSnackBar(snackBar);
                                  }
                                }
                              }
                            },
                            tooltip: localizations.check_updates,
                            icon: const Icon(Icons.update),
                          ),
                        ),
                      ],
                    ),
                  if (appState.connector!.portName == "Demo")
                    Container(
                      height: 48,
                      decoration: BoxDecoration(
                        color: appState.sharedPreferencesProvider
                            .getThemeComplementaryColor(),
                        borderRadius:
                            const BorderRadius.all(Radius.circular(8.0)),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Icon(
                            Icons.error_outline,
                          ),
                          const SizedBox(width: 16.0),
                          Expanded(
                            child: Text(
                              localizations.demo_firmware,
                              style: const TextStyle(
                                fontSize: 16.0,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (!areCapabilitiesSupported &&
                      appState.connector!.portName != "Demo")
                    Container(
                      height: 48,
                      decoration: BoxDecoration(
                        color: appState.sharedPreferencesProvider
                            .getThemeComplementaryColor(),
                        borderRadius:
                            const BorderRadius.all(Radius.circular(8.0)),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Icon(
                            Icons.error_outline,
                          ),
                          const SizedBox(width: 16.0),
                          Expanded(
                            child: Text(
                              localizations.please_update_firmware,
                              style: const TextStyle(
                                fontSize: 16.0,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: () async {
                              var localizations = AppLocalizations.of(context)!;
                              var scaffoldMessenger =
                                  ScaffoldMessenger.of(context);
                              var snackBar = SnackBar(
                                content: Text(localizations.downloading_fw(
                                    chameleonDeviceName(
                                        appState.connector!.device))),
                                action: SnackBarAction(
                                  label: localizations.close,
                                  onPressed: () {
                                    scaffoldMessenger.hideCurrentSnackBar();
                                  },
                                ),
                              );

                              scaffoldMessenger.showSnackBar(snackBar);
                              await flashFirmware(appState,
                                  scaffoldMessenger: scaffoldMessenger);
                            },
                            child: Text(localizations.update),
                          ),
                        ],
                      ),
                    ),
                  Align(
                    alignment: Alignment.bottomRight,
                    child: Row(
                      children: [
                        const Spacer(),
                        (isReaderDeviceMode)
                            ? Padding(
                                padding: const EdgeInsets.all(8.0),
                                child: IconButton(
                                  onPressed: () async {
                                    await appState.communicator!
                                        .setReaderDeviceMode(false);
                                    setState(() {});
                                    appState.changesMade();
                                  },
                                  tooltip: localizations.emulator_mode,
                                  icon: const Icon(Icons.nfc_sharp),
                                ),
                              )
                            : Padding(
                                padding: const EdgeInsets.all(8.0),
                                child: IconButton(
                                  onPressed: () async {
                                    await appState.communicator!
                                        .setReaderDeviceMode(true);
                                    setState(() {});
                                    appState.changesMade();
                                  },
                                  tooltip: localizations.reader_mode,
                                  icon: const Icon(Icons.barcode_reader),
                                ),
                              ),
                        Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: IconButton(
                            onPressed: () => showDialog<String>(
                                context: context,
                                builder: (BuildContext dialogContext) =>
                                    const ChameleonSettings()),
                            icon: const Icon(Icons.settings),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }
        },
      ),
    );
  }
}

class _LegacyHomePlaceholder extends StatelessWidget {
  const _LegacyHomePlaceholder({
    required this.device,
    this.errorMessage,
  });

  final ChameleonDevice device;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (errorMessage case final message?)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                '${localizations.error}: $message',
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 20),
          Text('${localizations.used_slots}: ${localizations.unknown}/8'),
          const FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              children: [
                Icon(Icons.circle_outlined),
                Icon(Icons.circle_outlined),
                Icon(Icons.circle_outlined),
                Icon(Icons.circle_outlined),
                Icon(Icons.circle_outlined),
                Icon(Icons.circle_outlined),
                Icon(Icons.circle_outlined),
                Icon(Icons.circle_outlined),
              ],
            ),
          ),
          Expanded(
            child: FractionallySizedBox(
              widthFactor: 0.4,
              child: Image.asset(
                device == ChameleonDevice.ultra
                    ? 'assets/black-ultra-standing-front.webp'
                    : 'assets/black-lite-standing-front.webp',
                fit: BoxFit.contain,
              ),
            ),
          ),
          Text('${localizations.firmware_version}: ${localizations.unknown}'),
          Align(
            alignment: Alignment.bottomRight,
            child: Row(
              children: [
                const Spacer(),
                IconButton(
                  onPressed: null,
                  tooltip: localizations.reader_mode,
                  icon: const Icon(Icons.barcode_reader),
                ),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: IconButton(
                    onPressed: () => showDialog<String>(
                      context: context,
                      builder: (_) => const ChameleonSettings(),
                    ),
                    icon: const Icon(Icons.settings),
                  ),
                ),
              ],
            ),
          ),
        ],
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
              message:
                  '${localizations.chameleon_connected}: ${identity.connectionType == ConnectionType.ble ? 'Bluetooth' : 'USB'}',
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
            IconButton(
              tooltip: localizations.close,
              onPressed: () => appState.disconnect(manual: true),
              icon: const Icon(Icons.link_off),
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
