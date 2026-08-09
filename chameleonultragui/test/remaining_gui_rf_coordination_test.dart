import 'dart:async';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/component/mifare/ultralight.dart';
import 'package:chameleonultragui/gui/menu/dialogs/slot/settings.dart';
import 'package:chameleonultragui/gui/page/debug.dart';
import 'package:chameleonultragui/helpers/card_info.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

late SharedPreferencesProvider _preferences;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = SharedPreferencesProvider();
    await _preferences.load();
  });

  testWidgets('Ultralight dump waits for foreground RF ownership',
      (tester) async {
    final communicator = _UltralightCommunicator();
    final appState = _connectedState(communicator);
    final releaseBackground = Completer<void>();
    final backgroundStarted = Completer<void>();
    final background = appState.rfOperations.tryRunBackground(() async {
      backgroundStarted.complete();
      await releaseBackground.future;
    });
    await backgroundStarted.future;

    await _pumpLocalized(
      tester,
      appState,
      MifareUltralightHelper(
        hfInfo: HFCardInfo(type: TagType.ultralight),
        allowSave: false,
      ),
    );
    final state = tester.state<CardReaderState>(
      find.byType(MifareUltralightHelper),
    );
    final read = state.readCard();
    await tester.pump();

    expect(communicator.rawCalls, 0);

    releaseBackground.complete();
    await background;
    await read;
    await tester.pump();

    expect(communicator.rawCalls, 18);
    expect(state.state, MifareUltralightState.save);
  });

  testWidgets('queued Ultralight dump rejects a replacement card model',
      (tester) async {
    final communicator = _UltralightCommunicator();
    final appState = _connectedState(communicator);
    final releaseBackground = Completer<void>();
    final background = appState.rfOperations.tryRunBackground(() async {
      await releaseBackground.future;
    });
    await tester.pump();
    final originalInfo = HFCardInfo(type: TagType.ultralight);

    await _pumpLocalized(
      tester,
      appState,
      MifareUltralightHelper(hfInfo: originalInfo, allowSave: false),
    );
    final state = tester.state<CardReaderState>(
      find.byType(MifareUltralightHelper),
    );
    final read = state.readCard();
    await tester.pump();

    final replacementInfo = HFCardInfo(type: TagType.ntag216);
    await _pumpLocalized(
      tester,
      appState,
      MifareUltralightHelper(hfInfo: replacementInfo, allowSave: false),
    );
    expect(
      tester.state<CardReaderState>(find.byType(MifareUltralightHelper)),
      same(state),
    );
    releaseBackground.complete();
    await background;
    await read;
    await tester.pump();

    expect(communicator.rawCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Ultralight dump stops after reconnect at an inner boundary',
      (tester) async {
    final communicator = _DelayedUltralightCommunicator();
    final appState = _connectedState(communicator);
    await _pumpLocalized(
      tester,
      appState,
      MifareUltralightHelper(
        hfInfo: HFCardInfo(type: TagType.ultralight),
        allowSave: false,
      ),
    );
    final state = tester.state<CardReaderState>(
      find.byType(MifareUltralightHelper),
    );

    final read = state.readCard();
    await communicator.started.future;
    final replacement = _UltralightCommunicator();
    _reconnect(appState, replacement);
    communicator.firstResponse.complete(Uint8List(16));
    await read;
    await tester.pump();

    expect(communicator.rawCalls, 1);
    expect(replacement.rawCalls, 0);
  });

  testWidgets('Ultralight dump stops when DFU starts at an inner boundary',
      (tester) async {
    final communicator = _DelayedUltralightCommunicator();
    final appState = _connectedState(communicator);
    await _pumpLocalized(
      tester,
      appState,
      MifareUltralightHelper(
        hfInfo: HFCardInfo(type: TagType.ultralight),
        allowSave: false,
      ),
    );
    final state = tester.state<CardReaderState>(
      find.byType(MifareUltralightHelper),
    );

    final read = state.readCard();
    await communicator.started.future;
    appState.connector!.isDFU = true;
    communicator.firstResponse.complete(Uint8List(16));
    await read;
    await tester.pump();

    expect(communicator.rawCalls, 1);
  });

  testWidgets('slot settings waits for RF ownership and keeps one lease',
      (tester) async {
    final communicator = _SlotCommunicator();
    final appState = _connectedState(communicator);
    final releaseBackground = Completer<void>();
    final backgroundStarted = Completer<void>();
    final background = appState.rfOperations.tryRunBackground(() async {
      backgroundStarted.complete();
      await releaseBackground.future;
    });
    await backgroundStarted.future;

    await _pumpLocalized(
      tester,
      appState,
      const SlotSettings(slot: 2),
    );
    await tester.pump();

    expect(communicator.commands, isEmpty);

    releaseBackground.complete();
    await background;
    await tester.pumpAndSettle();

    expect(communicator.commands, [
      'activate:2',
      'types',
      'enabled',
      'names',
      'active',
    ]);
    expect(
      (await appState.rfOperations.tryRunBackground(() async => true)).acquired,
      isTrue,
    );
  });

  testWidgets('slot settings stops after reconnect following activation',
      (tester) async {
    final communicator = _DelayedSlotCommunicator();
    final appState = _connectedState(communicator);

    await _pumpLocalized(
      tester,
      appState,
      const SlotSettings(slot: 3),
    );
    await communicator.activationStarted.future;
    final replacement = _SlotCommunicator();
    _reconnect(appState, replacement);
    communicator.activation.complete();
    await tester.pumpAndSettle();

    expect(communicator.commands, ['activate:3']);
    expect(replacement.commands, isEmpty);
  });

  testWidgets('slot settings holds foreground ownership through its last read',
      (tester) async {
    final communicator = _HoldingSlotCommunicator();
    final appState = _connectedState(communicator);

    await _pumpLocalized(
      tester,
      appState,
      const SlotSettings(slot: 1),
    );
    await communicator.lastReadStarted.future;

    expect(
      (await appState.rfOperations.tryRunBackground(() async => true)).acquired,
      isFalse,
    );

    communicator.lastRead.complete(List.generate(8, (_) => SlotTypes()));
    await tester.pumpAndSettle();

    expect(
      (await appState.rfOperations.tryRunBackground(() async => true)).acquired,
      isTrue,
    );
  });

  testWidgets('throwing slot workflow releases foreground ownership',
      (tester) async {
    final appState = _connectedState(_ThrowingSlotCommunicator());

    await _pumpLocalized(
      tester,
      appState,
      const SlotSettings(slot: 0),
    );
    await tester.pumpAndSettle();

    expect(
      (await appState.rfOperations.tryRunBackground(() async => true)).acquired,
      isTrue,
    );
  });

  testWidgets('Debug Copy UID waits for RF ownership as one workflow',
      (tester) async {
    final communicator = _CopyUidCommunicator();
    final appState = _connectedState(communicator);
    final releaseBackground = Completer<void>();
    final backgroundStarted = Completer<void>();
    final background = appState.rfOperations.tryRunBackground(() async {
      backgroundStarted.complete();
      await releaseBackground.future;
    });
    await backgroundStarted.future;
    await _pumpLocalized(tester, appState, const DebugPage());
    final copyUid = find.text('Copy card UID to emulator');
    await tester.ensureVisible(copyUid);
    await tester.tap(copyUid);
    await tester.pump();

    expect(communicator.commands, isEmpty);

    releaseBackground.complete();
    await background;
    await tester.pumpAndSettle();

    expect(communicator.commands, [
      'reader:true',
      'scan',
      'reader:false',
      'anti-collision',
    ]);
  });

  testWidgets('Debug Copy UID stops after reconnect during scan',
      (tester) async {
    final communicator = _DelayedCopyUidCommunicator();
    final appState = _connectedState(communicator);
    await _pumpLocalized(tester, appState, const DebugPage());
    final copyUid = find.text('Copy card UID to emulator');
    await tester.ensureVisible(copyUid);
    await tester.tap(copyUid);
    await communicator.scanStarted.future;

    final replacement = _CopyUidCommunicator();
    _reconnect(appState, replacement);
    communicator.scan.complete(_cardData());
    await tester.pumpAndSettle();

    expect(communicator.commands, ['reader:true', 'scan']);
    expect(replacement.commands, isEmpty);
  });

  testWidgets('Debug Copy UID stops after its page is disposed',
      (tester) async {
    final communicator = _DelayedCopyUidCommunicator();
    final appState = _connectedState(communicator);
    await _pumpLocalized(tester, appState, const DebugPage());
    final copyUid = find.text('Copy card UID to emulator');
    await tester.ensureVisible(copyUid);
    await tester.tap(copyUid);
    await communicator.scanStarted.future;

    await tester.pumpWidget(const SizedBox.shrink());
    communicator.scan.complete(_cardData());
    await tester.pumpAndSettle();

    expect(communicator.commands, ['reader:true', 'scan']);
  });
}

Future<void> _pumpLocalized(
  WidgetTester tester,
  ChameleonGUIState appState,
  Widget child,
) {
  return tester.pumpWidget(
    ChangeNotifierProvider<ChameleonGUIState>.value(
      value: appState,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      ),
    ),
  );
}

ChameleonGUIState _connectedState(ChameleonCommunicator communicator) {
  return ChameleonGUIState(_preferences)
    ..connector = (_TestSerial(log: Logger())..connected = true)
    ..communicator = communicator
    ..log = Logger();
}

void _reconnect(
  ChameleonGUIState appState,
  ChameleonCommunicator communicator,
) {
  appState.connector!.connected = false;
  appState
    ..connector = (_TestSerial(log: Logger())..connected = true)
    ..communicator = communicator;
}

class _UltralightCommunicator extends ChameleonCommunicator {
  int rawCalls = 0;

  _UltralightCommunicator() : super(Logger());

  @override
  Future<Uint8List> send14ARaw(
    Uint8List data, {
    int respTimeoutMs = 100,
    int? bitLen,
    bool activateRfField = true,
    bool waitResponse = true,
    bool appendCrc = true,
    bool autoSelect = true,
    bool keepRfField = false,
    bool checkResponseCrc = true,
  }) async {
    rawCalls++;
    if (data.first == 0x60) {
      return Uint8List(8);
    }
    if (data.first == 0x3C) {
      return Uint8List(32);
    }
    return Uint8List(16);
  }
}

class _DelayedUltralightCommunicator extends _UltralightCommunicator {
  final Completer<void> started = Completer<void>();
  final Completer<Uint8List> firstResponse = Completer<Uint8List>();

  @override
  Future<Uint8List> send14ARaw(
    Uint8List data, {
    int respTimeoutMs = 100,
    int? bitLen,
    bool activateRfField = true,
    bool waitResponse = true,
    bool appendCrc = true,
    bool autoSelect = true,
    bool keepRfField = false,
    bool checkResponseCrc = true,
  }) {
    rawCalls++;
    if (!started.isCompleted) {
      started.complete();
      return firstResponse.future;
    }
    return Future.value(Uint8List(16));
  }
}

class _SlotCommunicator extends ChameleonCommunicator {
  final List<String> commands = [];

  _SlotCommunicator() : super(Logger());

  @override
  Future<void> activateSlot(int slot) async {
    commands.add('activate:$slot');
  }

  @override
  Future<String> getSlotTagName(int index, TagFrequency frequency) async {
    commands.add('name:$index:${frequency.name}');
    return frequency.name;
  }

  @override
  Future<List<EnabledSlotInfo>> getEnabledSlots() async {
    commands.add('enabled');
    return List.generate(8, (_) => EnabledSlotInfo());
  }

  @override
  Future<List<SlotTypes>> getSlotTagTypes() async {
    commands.add('types');
    return List.generate(8, (_) => SlotTypes());
  }

  @override
  Future<List<SlotNames>> getSlotTagNames() async {
    commands.add('names');
    return List.generate(8, (_) => SlotNames());
  }

  @override
  Future<int> getActiveSlot() async {
    commands.add('active');
    return 0;
  }
}

class _DelayedSlotCommunicator extends _SlotCommunicator {
  final Completer<void> activationStarted = Completer<void>();
  final Completer<void> activation = Completer<void>();

  @override
  Future<void> activateSlot(int slot) {
    commands.add('activate:$slot');
    activationStarted.complete();
    return activation.future;
  }
}

class _HoldingSlotCommunicator extends _SlotCommunicator {
  final Completer<void> lastReadStarted = Completer<void>();
  final Completer<List<SlotTypes>> lastRead = Completer<List<SlotTypes>>();

  @override
  Future<List<SlotTypes>> getSlotTagTypes() {
    commands.add('types');
    lastReadStarted.complete();
    return lastRead.future;
  }
}

class _ThrowingSlotCommunicator extends _SlotCommunicator {
  @override
  Future<void> activateSlot(int slot) {
    throw StateError('activation failed');
  }
}

CardData _cardData() => CardData(
      uid: Uint8List.fromList([1, 2, 3, 4]),
      sak: 0x08,
      atqa: Uint8List.fromList([0x00, 0x04]),
      ats: Uint8List(0),
    );

class _CopyUidCommunicator extends ChameleonCommunicator {
  final List<String> commands = [];

  _CopyUidCommunicator() : super(Logger());

  @override
  Future<void> setReaderDeviceMode(bool readerMode) async {
    commands.add('reader:$readerMode');
  }

  @override
  Future<CardData?> scan14443aTag() async {
    commands.add('scan');
    return _cardData();
  }

  @override
  Future<void> setMf1AntiCollision(CardData card) async {
    commands.add('anti-collision');
  }
}

class _DelayedCopyUidCommunicator extends _CopyUidCommunicator {
  final Completer<void> scanStarted = Completer<void>();
  final Completer<CardData?> scan = Completer<CardData?>();

  @override
  Future<CardData?> scan14443aTag() {
    commands.add('scan');
    scanStarted.complete();
    return scan.future;
  }
}

class _TestSerial extends AbstractSerial {
  _TestSerial({required super.log});

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async => [];

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async => true;

  @override
  bool isManualConnectionSupported() => false;

  @override
  Future<bool> write(Uint8List command, {bool firmware = false}) async => true;
}
