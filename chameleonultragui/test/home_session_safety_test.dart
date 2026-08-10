import 'dart:async';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_emulator.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/page/home.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('Home status initialization waits for the foreground FIFO',
      (tester) async {
    final fixture = await _HomeFixture.create();
    addTearDown(fixture.dispose);
    final releaseLease = Completer<void>();
    final leaseEntered = Completer<void>();
    final lease = fixture.appState.rfOperations.runForeground(() async {
      leaseEntered.complete();
      await releaseLease.future;
    });
    await leaseEntered.future;

    await fixture.mount(tester);
    await tester.pump();
    expect(fixture.communicator.operations, isEmpty);

    releaseLease.complete();
    await lease;
    await tester.pumpAndSettle();

    expect(
      fixture.communicator.operations.take(6),
      [
        'slot-types',
        'battery',
        'firmware',
        'commit',
        'reader-mode',
        'capabilities',
      ],
    );
  });

  testWidgets('Home discards a status result after session replacement',
      (tester) async {
    final statusStarted = Completer<void>();
    final releaseStatus = Completer<void>();
    final fixture = await _HomeFixture.create(
      statusStarted: statusStarted,
      releaseStatus: releaseStatus,
    );
    addTearDown(fixture.dispose);

    await fixture.mount(tester);
    await statusStarted.future;
    final replacement = fixture.replaceCommunicator();
    releaseStatus.complete();
    for (var attempt = 0;
        attempt < 20 && !replacement.operations.contains('capabilities');
        attempt++) {
      await tester.pump();
    }
    await tester.pump();

    expect(fixture.communicator.operations, ['slot-types']);
    expect(
      replacement.operations.take(6),
      [
        'slot-types',
        'battery',
        'firmware',
        'commit',
        'reader-mode',
        'capabilities',
      ],
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}

class _HomeFixture {
  _HomeFixture._({
    required this.appState,
    required this.communicator,
    required this.connector,
    required this.logger,
  });

  final ChameleonGUIState appState;
  final _HomeCommunicator communicator;
  final EmulatorSerial connector;
  final Logger logger;

  static Future<_HomeFixture> create({
    Completer<void>? statusStarted,
    Completer<void>? releaseStatus,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    final logger = Logger(output: MemoryOutput());
    final connector = EmulatorSerial(log: logger);
    await connector.connectSpecificDevice('test-device');
    final communicator = _HomeCommunicator(
      logger,
      port: connector,
      statusStarted: statusStarted,
      releaseStatus: releaseStatus,
    );
    final appState = ChameleonGUIState(preferences)
      ..log = logger
      ..connector = connector
      ..communicator = communicator;
    return _HomeFixture._(
      appState: appState,
      communicator: communicator,
      connector: connector,
      logger: logger,
    );
  }

  _HomeCommunicator replaceCommunicator() {
    final replacement = _HomeCommunicator(logger, port: connector);
    appState.communicator = replacement;
    appState.changesMade();
    return replacement;
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<ChameleonGUIState>.value(
        value: appState,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const HomePage(),
        ),
      ),
    );
  }

  void dispose() {
    logger.close();
  }
}

class _HomeCommunicator extends ChameleonCommunicator {
  _HomeCommunicator(
    super.logger, {
    required super.port,
    this.statusStarted,
    this.releaseStatus,
  });

  final Completer<void>? statusStarted;
  final Completer<void>? releaseStatus;
  final List<String> operations = [];

  @override
  Future<List<SlotTypes>> getSlotTagTypes() async {
    operations.add('slot-types');
    statusStarted?.complete();
    await releaseStatus?.future;
    return List.generate(8, (_) => SlotTypes());
  }

  @override
  Future<BatteryCharge> getBatteryCharge() async {
    operations.add('battery');
    return BatteryCharge(percent: 80, voltage: 3900);
  }

  @override
  Future<FirmwareVersion> getFirmwareVersion() async {
    operations.add('firmware');
    return FirmwareVersion(legacyProtocol: false, version: 0x020100);
  }

  @override
  Future<String> getGitCommitHash() async {
    operations.add('commit');
    return 'abcdef0';
  }

  @override
  Future<bool> isReaderDeviceMode() async {
    operations.add('reader-mode');
    return false;
  }

  @override
  Future<List<int>> getDeviceCapabilities() async {
    operations.add('capabilities');
    return [ChameleonCommand.setIdteckEmulatorID.value];
  }

  @override
  Future<int> getActiveSlot() async {
    operations.add('active-slot');
    return 0;
  }
}
