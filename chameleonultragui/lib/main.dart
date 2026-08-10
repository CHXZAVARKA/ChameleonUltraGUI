import 'dart:io';
import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/connector/serial_android.dart';
import 'package:chameleonultragui/connector/serial_ble.dart';
import 'package:chameleonultragui/connector/serial_emulator.dart';
import 'package:chameleonultragui/connector/serial_macos.dart';
import 'package:chameleonultragui/gui/page/tools.dart';
import 'package:chameleonultragui/helpers/font.dart';
import 'package:chameleonultragui/helpers/connected_device_session.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/maintenance.dart';
import 'package:chameleonultragui/helpers/mifare_classic/maintenance_progress.dart';
import 'package:chameleonultragui/helpers/read_card_session.dart';
import 'package:chameleonultragui/helpers/rf_operation_coordinator.dart';
import 'package:chameleonultragui/status/connected_device_status.dart';
import 'package:chameleonultragui/status/firmware_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'connector/serial_native.dart';

// Page imports
import 'package:chameleonultragui/gui/page/home.dart';
import 'package:chameleonultragui/gui/page/saved_cards.dart';
import 'package:chameleonultragui/gui/page/settings.dart';
import 'package:chameleonultragui/gui/page/connect.dart';
import 'package:chameleonultragui/gui/page/debug.dart';
import 'package:chameleonultragui/gui/page/slot_manager.dart';
import 'package:chameleonultragui/gui/page/flashing.dart';
import 'package:chameleonultragui/gui/page/read_card.dart';
import 'package:chameleonultragui/gui/page/write_card.dart';
import 'package:chameleonultragui/gui/page/pending_connection.dart';

// Localizations
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';

// Shared Preferences Provider
import 'package:chameleonultragui/sharedprefsprovider.dart';

// Logger
import 'package:logger/logger.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final sharedPreferencesProvider = SharedPreferencesProvider();
  await sharedPreferencesProvider.load();
  runApp(ChameleonGUI(sharedPreferencesProvider));
}

class ChameleonGUI extends StatelessWidget {
  // Root Widget
  final SharedPreferencesProvider _sharedPreferencesProvider;
  const ChameleonGUI(this._sharedPreferencesProvider, {super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _sharedPreferencesProvider),
        ChangeNotifierProvider(
          create: (context) => ChameleonGUIState(_sharedPreferencesProvider),
        ),
      ],
      child: MainPage(sharedPreferencesProvider: _sharedPreferencesProvider),
    );
  }
}

class ChameleonGUIState extends ChangeNotifier {
  final SharedPreferencesProvider sharedPreferencesProvider;
  final FirmwareCatalog firmwareCatalog;
  final FirmwareInstaller? firmwareInstaller;

  ChameleonGUIState(
    this.sharedPreferencesProvider, {
    this.firmwareCatalog = const GitHubFirmwareCatalog(),
    this.firmwareInstaller,
  });

  RfOperationCoordinator _rfOperations = RfOperationCoordinator();
  RfOperationCoordinator get rfOperations => _rfOperations;

  ReadCardSession _readCardSession = ReadCardSession();

  AbstractSerial? _readCardSessionConnector;
  ChameleonCommunicator? _readCardSessionCommunicator;
  bool _readCardSessionConnected = false;
  bool _readCardSessionDfu = false;
  bool _readCardSessionBindingInitialized = false;
  StandardWriteActivity? _standardWriteActivity;

  final Map<Object, (AbstractSerial, ChameleonCommunicator)>
      _sessionWakelockOwners = {};
  bool _flashingWakelock = false;
  bool _wakelockRequested = false;
  Future<void> _wakelockUpdates = Future.value();

  SharedPreferencesProvider? _sharedPreferencesProvider;
  Logger? log; // Logger

  // Android uses AndroidSerial, iOS can only use BLESerial
  // The rest (desktops?) can use NativeSerial
  AbstractSerial? _connector;
  AbstractSerial? get connector => _connector;
  set connector(AbstractSerial? value) {
    if (identical(_connector, value)) {
      return;
    }
    _disposeConnectedDeviceStatus();
    _rfOperations = RfOperationCoordinator();
    _communicator = null;
    _connector = value;
    _synchronizeReadCardSession();
  }

  ChameleonCommunicator? _communicator;
  ChameleonCommunicator? get communicator => _communicator;
  set communicator(ChameleonCommunicator? value) {
    if (identical(_communicator, value)) {
      _attachConnectedDeviceStatusIfPossible();
      return;
    }
    _disposeConnectedDeviceStatus();
    _rfOperations = RfOperationCoordinator();
    _communicator = value;
    _attachConnectedDeviceStatusIfPossible();
    _synchronizeReadCardSession();
  }

  ReadCardSession get readCardSession {
    _synchronizeReadCardSession();
    return _readCardSession;
  }

  Object get connectedDeviceSessionToken => readCardSession;

  StandardWriteActivity? get standardWriteActivity {
    _synchronizeReadCardSession();
    return _standardWriteActivity;
  }

  void publishStandardWriteActivity({
    required AbstractSerial connector,
    required ChameleonCommunicator communicator,
    required StandardWriteActivity activity,
  }) {
    _synchronizeReadCardSession();
    if (!_readCardSessionConnected ||
        _readCardSessionDfu ||
        !identical(_connector, connector) ||
        !identical(_communicator, communicator)) {
      return;
    }
    _standardWriteActivity = activity;
    notifyListeners();
  }

  ConnectedDeviceStatus? _connectedDeviceStatus;
  ConnectedDeviceStatus? get connectedDeviceStatus => _connectedDeviceStatus;

  bool devMode = false;
  double? progress; // DFU

  // Flashing easter egg
  bool easterEgg = false;
  dynamic _suppressedAutoReconnectPort;

  GlobalKey navigationRailKey = GlobalKey();
  Size? navigationRailSize;

  void changesMade() {
    _synchronizeReadCardSession();
    notifyListeners();
  }

  void onConnectorStateChanged() {
    if (connector == null || !connector!.connected || connector!.isDFU) {
      communicator = null;
      progress = null;
    } else {
      _attachConnectedDeviceStatusIfPossible();
    }
    _synchronizeReadCardSession();
    notifyListeners();
  }

  void _synchronizeReadCardSession() {
    final connector = _connector;
    final communicator = _communicator;
    final connected = connector?.connected == true;
    final isDfu = connector?.isDFU == true;
    final bindingChanged = !_readCardSessionBindingInitialized ||
        !identical(_readCardSessionConnector, connector) ||
        !identical(_readCardSessionCommunicator, communicator) ||
        _readCardSessionConnected != connected ||
        _readCardSessionDfu != isDfu;
    if (!bindingChanged) {
      return;
    }

    if (_readCardSessionBindingInitialized) {
      _readCardSession = ReadCardSession();
      _standardWriteActivity = null;
      _sessionWakelockOwners.clear();
      _updateWakelock();
    }
    _readCardSessionConnector = connector;
    _readCardSessionCommunicator = communicator;
    _readCardSessionConnected = connected;
    _readCardSessionDfu = isDfu;
    _readCardSessionBindingInitialized = true;
  }

  Object? acquireSessionWakelock({
    required AbstractSerial connector,
    required ChameleonCommunicator communicator,
  }) {
    _synchronizeReadCardSession();
    if (!_readCardSessionConnected ||
        _readCardSessionDfu ||
        !identical(_connector, connector) ||
        !identical(_communicator, communicator)) {
      return null;
    }

    final owner = Object();
    _sessionWakelockOwners[owner] = (connector, communicator);
    _updateWakelock();
    return owner;
  }

  void releaseSessionWakelock(Object? owner) {
    if (owner == null || _sessionWakelockOwners.remove(owner) == null) {
      return;
    }
    _updateWakelock();
  }

  void setFlashingWakelock(bool enable) {
    if (_flashingWakelock == enable) {
      return;
    }
    _flashingWakelock = enable;
    _updateWakelock();
  }

  void _updateWakelock() {
    final enable = _flashingWakelock || _sessionWakelockOwners.isNotEmpty;
    if (_wakelockRequested == enable) {
      return;
    }
    _wakelockRequested = enable;
    _wakelockUpdates = _wakelockUpdates.then((_) async {
      try {
        await WakelockPlus.toggle(enable: enable);
      } catch (_) {}
    });
  }

  bool isAutoReconnectSuppressed(dynamic devicePort) {
    return _suppressedAutoReconnectPort == devicePort;
  }

  void clearAutoReconnectSuppression([dynamic devicePort]) {
    if (devicePort == null || _suppressedAutoReconnectPort == devicePort) {
      _suppressedAutoReconnectPort = null;
    }
  }

  void syncAutoReconnectSuppression(Iterable<dynamic> visiblePorts) {
    if (_suppressedAutoReconnectPort == null) {
      return;
    }

    for (final port in visiblePorts) {
      if (port == _suppressedAutoReconnectPort) {
        return;
      }
    }

    _suppressedAutoReconnectPort = null;
  }

  Future<void> disconnect({bool manual = false}) async {
    final suppressedPort = manual ? connector?.activeDevicePort : null;
    _disposeConnectedDeviceStatus();
    await connector?.performDisconnect();
    if (manual && suppressedPort != null) {
      _suppressedAutoReconnectPort = suppressedPort;
    }
    communicator = null;
    progress = null;
    notifyListeners();
  }

  void setProgressBar(dynamic value) {
    progress = value;
    notifyListeners();
  }

  bool hasConnectedCommunicator(ChameleonCommunicator candidate) {
    return connector?.connected == true &&
        connector?.isDFU != true &&
        identical(communicator, candidate);
  }

  void _attachConnectedDeviceStatusIfPossible() {
    if (_connectedDeviceStatus != null) {
      return;
    }
    final session = ConnectedDeviceSession.capture(this);
    if (session == null) {
      return;
    }
    _connectedDeviceStatus = ConnectedDeviceStatus(
      session: session,
      rfOperations: rfOperations,
      firmwareCatalog: firmwareCatalog,
      firmwareInstaller: firmwareInstaller,
      firmwareChannel: sharedPreferencesProvider.getFirmwareChannel(),
    );
  }

  void _disposeConnectedDeviceStatus() {
    _connectedDeviceStatus?.dispose();
    _connectedDeviceStatus = null;
  }

  @override
  void dispose() {
    _disposeConnectedDeviceStatus();
    _sessionWakelockOwners.clear();
    _flashingWakelock = false;
    _updateWakelock();
    super.dispose();
  }
}

enum StandardWriteActivityState { active, succeeded, failed, cancelled }

class StandardWriteActivity {
  const StandardWriteActivity({
    required this.state,
    required this.progress,
  });

  final StandardWriteActivityState state;
  final MifareClassicMaintenanceProgress progress;

  bool get isActive => state == StandardWriteActivityState.active;
}

const _readCardNavigationIndex = 3;
const _writeCardNavigationIndex = 4;

class MainPage extends StatefulWidget {
  const MainPage({super.key, required this.sharedPreferencesProvider});

  final SharedPreferencesProvider sharedPreferencesProvider;

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  var selectedIndex = 0;
  Object? _writeCardPageSessionToken;
  GlobalKey<WriteCardPageState> _writeCardPageKey =
      GlobalKey<WriteCardPageState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => updateNavigationRailWidth(context));
  }

  @override
  void reassemble() async {
    // Disconnect on reload
    var appState = Provider.of<ChameleonGUIState>(context, listen: false);
    await appState.disconnect();

    super.reassemble();
  }

  AbstractSerial getConnector(ChameleonGUIState appState) {
    if (appState._sharedPreferencesProvider!.isEmulatedChameleon()) {
      return EmulatorSerial(log: appState.log!);
    }

    if (Platform.isMacOS) {
      return MacOSSerial(log: appState.log!);
    }

    if (Platform.isAndroid) {
      return AndroidSerial(log: appState.log!);
    }

    if (Platform.isIOS) {
      return BLESerial(log: appState.log!);
    }

    return NativeSerial(log: appState.log!);
  }

  Logger getLogger(ChameleonGUIState appState) {
    if (appState._sharedPreferencesProvider!.isDebugLogging() &&
        appState._sharedPreferencesProvider!.isDebugMode()) {
      return Logger(
        output: SharedPreferencesLogger(appState._sharedPreferencesProvider!),
        printer: PrettyPrinter(
          noBoxingByDefault: true,
        ),
        filter: ChameleonLogFilter(),
      );
    } else {
      return Logger();
    }
  }

  @override
  Widget build(BuildContext context) {
    var appState = context.watch<ChameleonGUIState>();
    const readCardPage = ReadCardPage(
      key: ValueKey('read-card-page'),
    );
    appState._sharedPreferencesProvider = widget.sharedPreferencesProvider;
    appState.log ??= getLogger(appState);
    appState.connector ??= getConnector(appState);
    appState.connector!.connectionStateCallback =
        appState.onConnectorStateChanged;

    if (appState.sharedPreferencesProvider.getSideBarAutoExpansion()) {
      double width = MediaQuery.of(context).size.width;
      if (width >= 600) {
        appState.sharedPreferencesProvider.setSideBarExpanded(true);
      } else {
        appState.sharedPreferencesProvider.setSideBarExpanded(false);
      }
    }

    appState.devMode = appState.sharedPreferencesProvider.isDebugMode();
    final connectedDeviceSessionToken = appState.connectedDeviceSessionToken;
    if (!identical(_writeCardPageSessionToken, connectedDeviceSessionToken)) {
      _writeCardPageSessionToken = connectedDeviceSessionToken;
      _writeCardPageKey = GlobalKey<WriteCardPageState>();
    }
    final writeCardPage = WriteCardPage(key: _writeCardPageKey);
    final standardWriteActivity = appState.standardWriteActivity;

    Widget page; // Set Page
    if (!appState.connector!.connected &&
        selectedIndex != 0 &&
        selectedIndex != 2 &&
        selectedIndex != 5 &&
        selectedIndex != 6 &&
        selectedIndex != 7) {
      // If not connected, and not on home, tools, settings or dev page, go to home page
      selectedIndex = 0;
    }

    switch (selectedIndex) {
      // Sidebar Navigation
      case 0:
        if (appState.connector!.pendingConnection) {
          page = const PendingConnectionPage();
        } else {
          if (appState.connector!.connected) {
            if (appState.connector!.isDFU) {
              page = const FlashingPage();
            } else {
              page = const HomePage();
            }
          } else {
            page = const ConnectPage();
          }
        }
        break;
      case 1:
        page = const SlotManagerPage();
        break;
      case 2:
        page = const SavedCardsPage();
        break;
      case _readCardNavigationIndex:
        page = readCardPage;
        break;
      case _writeCardNavigationIndex:
        page = writeCardPage;
        break;
      case 5:
        page = const ToolsPage();
        break;
      case 6:
        page = const SettingsMainPage();
        break;
      case 7:
        page = const DebugPage();
        break;
      default:
        throw UnimplementedError('no widget for $selectedIndex');
    }

    final isDfu = appState.connector!.connected && appState.connector!.isDFU;
    final foregroundPage = isDfu ? const FlashingPage() : page;
    final canMountReadCard = appState.connector!.connected && !isDfu;
    final isReadCardVisible =
        canMountReadCard && selectedIndex == _readCardNavigationIndex;
    final canMountWriteCard = appState.connector!.connected && !isDfu;
    final isWriteCardVisible =
        canMountWriteCard && selectedIndex == _writeCardNavigationIndex;

    appState.setFlashingWakelock(foregroundPage is FlashingPage);

    final pageContent = Stack(
      fit: StackFit.expand,
      children: [
        if (canMountReadCard)
          Offstage(
            key: const ValueKey('persistent-read-card'),
            offstage: !isReadCardVisible,
            child: readCardPage,
          ),
        if (canMountWriteCard)
          Offstage(
            key: const ValueKey('persistent-write-card'),
            offstage: !isWriteCardVisible,
            child: writeCardPage,
          ),
        if (!isReadCardVisible && !isWriteCardVisible)
          KeyedSubtree(
            key: ValueKey(
              isDfu ? 'foreground-page-dfu' : 'foreground-page-$selectedIndex',
            ),
            child: foregroundPage,
          ),
      ],
    );

    return MaterialApp(
      title: 'Chameleon Ultra GUI', // App Name
      locale: widget.sharedPreferencesProvider.getLocale(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
            seedColor: widget.sharedPreferencesProvider.getThemeColor()),
        brightness: Brightness.light,
        appBarTheme: AppBarTheme(
            systemOverlayStyle: SystemUiOverlayStyle(
                statusBarColor: ColorScheme.fromSeed(
                        seedColor:
                            widget.sharedPreferencesProvider.getThemeColor(),
                        brightness: Brightness.light)
                    .surface,
                statusBarBrightness: Brightness.light,
                statusBarIconBrightness: Brightness.dark)),
      ).useCustomSystemFont(Brightness.light),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
            seedColor: widget.sharedPreferencesProvider.getThemeColor(),
            brightness: Brightness.dark),
        brightness: Brightness.dark,
        appBarTheme: AppBarTheme(
            systemOverlayStyle: SystemUiOverlayStyle(
                statusBarColor: ColorScheme.fromSeed(
                        seedColor:
                            widget.sharedPreferencesProvider.getThemeColor(),
                        brightness: Brightness.dark)
                    .surface,
                statusBarBrightness: Brightness.dark,
                statusBarIconBrightness: Brightness.light)),
      ).useCustomSystemFont(Brightness.dark),
      themeMode: widget.sharedPreferencesProvider.getTheme(), // Dark Theme
      home: LayoutBuilder(// Build Page
          builder: (context, constraints) {
        final standardWriteProgress = standardWriteActivity?.isActive == true
            ? MifareClassicMaintenanceProgressPresenter(
                standardWriteActivity!.progress,
                AppLocalizations.of(context)!,
              )
            : null;
        return SafeArea(
          left: false,
          right: false,
          top: false,
          bottom: true,
          child: Scaffold(
              body: Row(
                children: [
                  (!appState.connector!.isDFU || !appState.connector!.connected)
                      ? SafeArea(
                          child: NavigationRail(
                            key: appState.navigationRailKey,
                            // Sidebar
                            extended: appState.sharedPreferencesProvider
                                .getSideBarExpanded(),
                            destinations: [
                              // Sidebar Items
                              NavigationRailDestination(
                                icon: const Icon(Icons.home),
                                label: Text(
                                    AppLocalizations.of(context)!.home), // Home
                              ),
                              NavigationRailDestination(
                                disabled: !appState.connector!.connected,
                                icon: const Icon(Icons.widgets),
                                label: Text(
                                    AppLocalizations.of(context)!.slot_manager),
                              ),
                              NavigationRailDestination(
                                icon: const Icon(Icons.auto_awesome_motion),
                                label: Text(
                                    AppLocalizations.of(context)!.saved_cards),
                              ),
                              NavigationRailDestination(
                                disabled: !appState.connector!.connected,
                                icon: const Icon(Icons.sensors),
                                label: Text(
                                    AppLocalizations.of(context)!.read_card),
                              ),
                              NavigationRailDestination(
                                disabled: !appState.connector!.connected,
                                icon: standardWriteProgress == null
                                    ? const Icon(Icons.system_update_alt)
                                    : Semantics(
                                        key: const ValueKey(
                                          'standard-write-navigation-activity',
                                        ),
                                        container: true,
                                        label:
                                            '${AppLocalizations.of(context)!.write_card}. '
                                            '${standardWriteProgress.label}',
                                        child: ExcludeSemantics(
                                          child: Badge(
                                            smallSize: 8,
                                            child: const Icon(
                                              Icons.system_update_alt,
                                            ),
                                          ),
                                        ),
                                      ),
                                label: Text(
                                    AppLocalizations.of(context)!.write_card),
                              ),
                              NavigationRailDestination(
                                icon: const Icon(Icons.handyman),
                                label:
                                    Text(AppLocalizations.of(context)!.tools),
                              ),
                              NavigationRailDestination(
                                icon: const Icon(Icons.settings),
                                label: Text(
                                    AppLocalizations.of(context)!.settings),
                              ),
                              if (appState.devMode)
                                NavigationRailDestination(
                                  icon: const Icon(Icons.bug_report),
                                  label: Text(
                                      '🐞 ${AppLocalizations.of(context)!.debug} 🐞'),
                                ),
                            ],
                            selectedIndex: selectedIndex,
                            onDestinationSelected: (value) {
                              setState(() {
                                selectedIndex = value;
                              });
                            },
                          ),
                        )
                      : const SizedBox(),
                  Expanded(
                    child: Container(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      child: pageContent,
                    ),
                  ),
                ],
              ),
              bottomNavigationBar: BottomProgressBar(
                onStandardWriteTap: () {
                  _writeCardPageKey.currentState?.selectStandardMode();
                  setState(() {
                    selectedIndex = _writeCardNavigationIndex;
                  });
                },
              )),
        );
      }),
    );
  }
}

class BottomProgressBar extends StatelessWidget {
  const BottomProgressBar({
    super.key,
    required this.onStandardWriteTap,
  });

  final VoidCallback onStandardWriteTap;

  @override
  Widget build(BuildContext context) {
    var appState = context.watch<ChameleonGUIState>();
    if (appState.connector!.connected && appState.connector!.isDFU) {
      return LinearProgressIndicator(
        value: appState.progress,
        backgroundColor: Colors.grey[300],
        valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
      );
    }

    final activity = appState.standardWriteActivity;
    if (activity == null || !activity.isActive) {
      return const SizedBox();
    }
    final localizations = AppLocalizations.of(context)!;
    final progress = MifareClassicMaintenanceProgressPresenter(
      activity.progress,
      localizations,
    );
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Semantics(
        key: const ValueKey('standard-write-global-progress'),
        container: true,
        label: '${localizations.write_card}. ${progress.label}',
        hint: localizations.write_card,
        liveRegion: true,
        button: true,
        onTap: onStandardWriteTap,
        onTapHint: localizations.write_card,
        child: ExcludeSemantics(
          child: InkWell(
            onTap: onStandardWriteTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.system_update_alt, size: 18),
                      const SizedBox(width: 8),
                      Expanded(child: Text(progress.label)),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                  const SizedBox(height: 6),
                  LinearProgressIndicator(value: progress.fraction),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
