import 'dart:async';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/connector/serial_emulator.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/page/read_card.dart';
import 'package:chameleonultragui/gui/page/saved_cards.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/mifare_classic/recovery.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/key_profile.dart';
import 'package:chameleonultragui/helpers/read_card_session.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _mifareUltralightGetVersionCommand = 0x60;
const _mifareUltralightReadSignatureCommand = 0x3C;

void main() {
  testWidgets('Read Card keeps running while another tab is visible', (
    tester,
  ) async {
    final fixture = await _ReadCardFixture.mount(
      tester,
      communicatorFactory: (logger, connector) =>
          _ContinuousBothCommunicator(logger, port: connector),
    );
    final initialState = await fixture.openReadCard();
    final recovery = MifareClassicRecovery(
      appState: fixture.appState,
      update: initialState.updateMifareClassicRecovery,
      localizations: await AppLocalizations.delegate.load(const Locale('en')),
      mifareClassicType: MifareClassicType.m1k,
    );
    await initialState.startContinuousHFScan();
    await initialState.startContinuousLFScan();
    initialState
      ..hfInfo = HFCardInfo(
        uid: '01 02 03 04',
        sak: '08',
        atqa: '00 04',
        tech: 'MIFARE Classic 1K',
      )
      ..mfcInfo = (MifareClassicInfo(
        type: MifareClassicType.m1k,
        state: MifareClassicState.recovery,
      )..recovery = recovery)
      ..scanInProgress = true
      ..updateMifareClassicInfo();
    await tester.pump();

    expect(find.textContaining('01 02 03 04'), findsOneWidget);

    await fixture.openSavedCards();
    expect(find.byType(ReadCardPage), findsNothing);
    expect(find.byType(ReadCardPage, skipOffstage: false), findsOneWidget);
    expect(initialState.mounted, isTrue);
    expect(initialState.isContinuousHFScan, isTrue);
    expect(initialState.isContinuousLFScan, isTrue);

    recovery.update();
    await tester.pump();
    expect(tester.takeException(), isNull);

    final restoredState = await fixture.openReadCard();
    expect(restoredState, same(initialState));
    expect(restoredState.hfInfo.uid, '01 02 03 04');
    expect(restoredState.mfcInfo.recovery, same(recovery));
    expect(recovery.update, restoredState.updateMifareClassicRecovery);
    expect(restoredState.isContinuousHFScan, isTrue);
    expect(restoredState.isContinuousLFScan, isTrue);
    expect(restoredState.scanInProgress, isTrue);
    restoredState.stopContinuousHFScan();
    restoredState.stopContinuousLFScan();
  });

  testWidgets('pending HF read updates the session while Read Card is hidden', (
    tester,
  ) async {
    final fixture = await _ReadCardFixture.mount(
      tester,
      communicatorFactory: (logger, connector) =>
          _PendingHFCommunicator(logger, port: connector),
    );
    final communicator = fixture.communicator as _PendingHFCommunicator;
    final initialState = await fixture.openReadCard();

    final originalInfo = HFCardInfo(uid: 'persisted');
    fixture.appState.readCardSession.hfInfo = originalInfo;
    await tester.tap(find.widgetWithText(ElevatedButton, 'Read').first);
    await tester.pump();
    expect(communicator.scanStarted.isCompleted, isTrue);

    await fixture.openSavedCards();
    expect(find.byType(ReadCardPage), findsNothing);
    expect(initialState.mounted, isTrue);
    communicator.completeScan(
      CardData(
        uid: Uint8List.fromList([1, 2, 3, 4]),
        sak: 0x08,
        atqa: Uint8List.fromList([0x00, 0x04]),
        ats: Uint8List(0),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(communicator.detectCalls, 1);
    expect(fixture.appState.readCardSession.hfInfo, isNot(same(originalInfo)));
    expect(fixture.appState.readCardSession.hfInfo.uid, '01 02 03 04');

    expect(await fixture.openReadCard(), same(initialState));
    expect(find.textContaining('01 02 03 04'), findsOneWidget);
  });

  testWidgets('canceled queued HF read does not clear its replacement', (
    tester,
  ) async {
    final fixture = await _ReadCardFixture.mount(
      tester,
      physicalSize: const Size(799, 1600),
      directReadCard: true,
    );
    final readCardState = await fixture.openReadCard();
    final replacement = _PendingHFCommunicator(
      fixture.logger,
      port: fixture.connector,
    );
    final foregroundBlocker = Completer<void>();
    final background = fixture.appState.rfOperations.tryRunBackground(() async {
      await foregroundBlocker.future;
    });
    await tester.pump();

    await tester.tap(find.widgetWithText(ElevatedButton, 'Read').first);
    await tester.pump();
    expect(readCardState.scanInProgress, isTrue);

    fixture.appState
      ..communicator = replacement
      ..changesMade();
    await tester.pump();

    expect(readCardState.scanInProgress, isFalse);
    await tester.tap(find.widgetWithText(ElevatedButton, 'Read').first);
    await tester.pump();
    expect(readCardState.scanInProgress, isTrue);

    foregroundBlocker.complete();
    await background;
    await tester.pump();

    expect(replacement.scanStarted.isCompleted, isTrue);
    expect(readCardState.scanInProgress, isTrue);
    expect(
      tester
          .widget<ElevatedButton>(
            find.widgetWithText(ElevatedButton, 'Read').first,
          )
          .onPressed,
      isNull,
    );

    replacement.completeScan(null);
    await tester.pump();

    expect(readCardState.scanInProgress, isFalse);
    expect(
      tester
          .widget<ElevatedButton>(
            find.widgetWithText(ElevatedButton, 'Read').first,
          )
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('queued manual LF read becomes actionable after reconnect', (
    tester,
  ) async {
    final fixture = await _ReadCardFixture.mount(
      tester,
      physicalSize: const Size(799, 1600),
      directReadCard: true,
    );
    final readCardState = await fixture.openReadCard();
    final replacement = _PendingLFCommunicator(
      fixture.logger,
      port: fixture.connector,
    );
    final foregroundBlocker = Completer<void>();
    final background = fixture.appState.rfOperations.tryRunBackground(() async {
      await foregroundBlocker.future;
    });
    await tester.pump();

    await tester.tap(find.widgetWithText(ElevatedButton, 'Read').last);
    await tester.pump();
    expect(readCardState.scanInProgress, isTrue);

    fixture.appState
      ..communicator = replacement
      ..changesMade();
    await tester.pump();

    expect(readCardState.scanInProgress, isFalse);
    expect(
      tester
          .widget<ElevatedButton>(
            find.widgetWithText(ElevatedButton, 'Read').last,
          )
          .onPressed,
      isNotNull,
    );

    foregroundBlocker.complete();
    await background;
    await tester.pump();

    expect(replacement.readStarted.isCompleted, isFalse);
    expect(readCardState.scanInProgress, isFalse);
    expect(
      tester
          .widget<ElevatedButton>(
            find.widgetWithText(ElevatedButton, 'Read').last,
          )
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('queued manual HF read rejects a replacement connector', (
    tester,
  ) async {
    final fixture = await _ReadCardFixture.mount(
      tester,
      communicatorFactory: (logger, connector) =>
          _ContinuousHFCommunicator(logger, port: connector),
    );
    final communicator = fixture.communicator as _ContinuousHFCommunicator;
    await fixture.openReadCard();
    final blocker = Completer<void>();
    final background = fixture.appState.rfOperations.tryRunBackground(() async {
      await blocker.future;
    });
    await tester.pump();

    await tester.tap(find.widgetWithText(ElevatedButton, 'Read').first);
    await tester.pump();
    fixture.appState
      ..connector = (EmulatorSerial(log: fixture.logger)
        ..connected = true
        ..device = ChameleonDevice.ultra
        ..connectionType = ConnectionType.usb)
      ..changesMade();
    blocker.complete();
    await background;
    await tester.pump();

    expect(communicator.scanCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('queued manual HF read does not start after page disposal', (
    tester,
  ) async {
    final fixture = await _ReadCardFixture.mount(
      tester,
      communicatorFactory: (logger, connector) =>
          _ContinuousHFCommunicator(logger, port: connector),
    );
    final communicator = fixture.communicator as _ContinuousHFCommunicator;
    await fixture.openReadCard();
    final blocker = Completer<void>();
    final background = fixture.appState.rfOperations.tryRunBackground(() async {
      await blocker.future;
    });
    await tester.pump();

    await tester.tap(find.widgetWithText(ElevatedButton, 'Read').first);
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    blocker.complete();
    await background;
    await tester.pump();

    expect(communicator.scanCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('queued manual LF read does not start after page disposal', (
    tester,
  ) async {
    final fixture = await _ReadCardFixture.mount(
      tester,
      communicatorFactory: (logger, connector) =>
          _ContinuousLFCommunicator(logger, port: connector),
    );
    final communicator = fixture.communicator as _ContinuousLFCommunicator;
    await fixture.openReadCard();
    final blocker = Completer<void>();
    final background = fixture.appState.rfOperations.tryRunBackground(() async {
      await blocker.future;
    });
    await tester.pump();

    await tester.tap(find.widgetWithText(ElevatedButton, 'Read').last);
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    blocker.complete();
    await background;
    await tester.pump();

    expect(communicator.readCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending LF read updates the session while Read Card is hidden', (
    tester,
  ) async {
    final fixture = await _ReadCardFixture.mount(
      tester,
      communicatorFactory: (logger, connector) =>
          _PendingLFCommunicator(logger, port: connector),
    );
    final communicator = fixture.communicator as _PendingLFCommunicator;
    final initialState = await fixture.openReadCard();

    await tester.tap(find.widgetWithText(ElevatedButton, 'Read').last);
    await tester.pump();
    expect(communicator.readStarted.isCompleted, isTrue);
    final pendingInfo = fixture.appState.readCardSession.lfInfo;

    await fixture.openSavedCards();
    expect(find.byType(ReadCardPage), findsNothing);
    expect(initialState.mounted, isTrue);
    final card = EM410XCard.fromUID('0102030405');
    communicator.completeRead(card);
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(communicator.followUpCalls, 0);
    expect(fixture.appState.readCardSession.lfInfo, same(pendingInfo));
    expect(fixture.appState.readCardSession.lfInfo.card, same(card));
    expect(fixture.appState.readCardSession.lfInfo.cardExist, isTrue);

    expect(await fixture.openReadCard(), same(initialState));
    expect(find.textContaining('01 02 03 04 05'), findsOneWidget);
  });

  testWidgets('disconnect disposes hidden Read Card and cancels its timers', (
    tester,
  ) async {
    final fixture = await _ReadCardFixture.mount(
      tester,
      communicatorFactory: (logger, connector) =>
          _ContinuousBothCommunicator(logger, port: connector),
    );
    final readCardState = await fixture.openReadCard();
    final communicator = fixture.communicator as _ContinuousBothCommunicator;
    await readCardState.startContinuousHFScan();
    await readCardState.startContinuousLFScan();
    final hfCallsBeforeDisconnect = communicator.scanCalls;
    final lfCallsBeforeDisconnect = communicator.readCalls;

    await fixture.openSavedCards();
    expect(readCardState.mounted, isTrue);

    await fixture.appState.disconnect(manual: true);
    await tester.pumpAndSettle();

    expect(find.byType(ReadCardPage, skipOffstage: false), findsNothing);
    expect(readCardState.mounted, isFalse);
    expect(readCardState.isContinuousHFScan, isFalse);
    expect(readCardState.isContinuousLFScan, isFalse);
    await tester.pump(const Duration(seconds: 4));
    expect(communicator.scanCalls, hfCallsBeforeDisconnect);
    expect(communicator.readCalls, lfCallsBeforeDisconnect);
  });

  testWidgets(
    'delayed HF response after disconnect cannot continue or mutate session',
    (tester) async {
      final fixture = await _ReadCardFixture.mount(
        tester,
        communicatorFactory: (logger, connector) =>
            _PendingHFCommunicator(logger, port: connector),
      );
      final communicator = fixture.communicator as _PendingHFCommunicator;
      final readCardState = await fixture.openReadCard();
      final originalInfo = HFCardInfo(uid: 'persisted');
      fixture.appState.readCardSession.hfInfo = originalInfo;

      await tester.tap(find.widgetWithText(ElevatedButton, 'Read').first);
      await tester.pump();
      expect(communicator.scanStarted.isCompleted, isTrue);

      await fixture.connector.performDisconnect();
      expect(readCardState.mounted, isTrue);
      communicator.completeScan(
        CardData(
          uid: Uint8List.fromList([1, 2, 3, 4]),
          sak: 0x08,
          atqa: Uint8List.fromList([0x00, 0x04]),
          ats: Uint8List(0),
        ),
      );
      await tester.idle();

      expect(tester.takeException(), isNull);
      expect(communicator.detectCalls, 0);
      expect(fixture.appState.readCardSession.hfInfo, same(originalInfo));
      expect(fixture.appState.readCardSession.hfInfo.uid, 'persisted');
    },
  );

  testWidgets(
    'delayed LF response after disconnect cannot continue or mutate session',
    (tester) async {
      final fixture = await _ReadCardFixture.mount(
        tester,
        communicatorFactory: (logger, connector) =>
            _PendingLFCommunicator(logger, port: connector),
      );
      final communicator = fixture.communicator as _PendingLFCommunicator;
      final readCardState = await fixture.openReadCard();

      await tester.tap(find.widgetWithText(ElevatedButton, 'Read').last);
      await tester.pump();
      expect(communicator.readStarted.isCompleted, isTrue);
      final pendingInfo = fixture.appState.readCardSession.lfInfo;

      await fixture.connector.performDisconnect();
      expect(readCardState.mounted, isTrue);
      communicator.completeRead(null);
      await tester.idle();

      expect(tester.takeException(), isNull);
      expect(communicator.followUpCalls, 0);
      expect(fixture.appState.readCardSession.lfInfo, same(pendingInfo));
      expect(pendingInfo.card, isNull);
    },
  );

  testWidgets(
    'disconnect cancels MIFARE Classic scan before its next RF command',
    (tester) async {
      final fixture = await _ReadCardFixture.mount(
        tester,
        communicatorFactory: (logger, connector) =>
            _InnerClassicBoundaryCommunicator(logger, port: connector),
      );
      final communicator =
          fixture.communicator as _InnerClassicBoundaryCommunicator;
      final readCardState = await fixture.openReadCard();
      final originalInfo = HFCardInfo(uid: 'persisted');
      fixture.appState.readCardSession.hfInfo = originalInfo;

      await tester.tap(find.widgetWithText(ElevatedButton, 'Read').first);
      await tester.pump();
      expect(communicator.innerCommandStarted.isCompleted, isTrue);

      await fixture.connector.performDisconnect();
      expect(readCardState.mounted, isTrue);
      communicator.completeInnerCommand();
      await tester.idle();

      expect(tester.takeException(), isNull);
      expect(communicator.innerCommandCalls, 1);
      expect(communicator.followUpCalls, 0);
      expect(fixture.appState.readCardSession.hfInfo, same(originalInfo));
    },
  );

  testWidgets('DFU cancels Ultralight scan before its next RF command', (
    tester,
  ) async {
    final fixture = await _ReadCardFixture.mount(
      tester,
      communicatorFactory: (logger, connector) =>
          _InnerUltralightBoundaryCommunicator(logger, port: connector),
    );
    final communicator =
        fixture.communicator as _InnerUltralightBoundaryCommunicator;
    final readCardState = await fixture.openReadCard();
    final originalInfo = HFCardInfo(uid: 'persisted');
    fixture.appState.readCardSession.hfInfo = originalInfo;

    await tester.tap(find.widgetWithText(ElevatedButton, 'Read').first);
    await tester.pump();
    expect(communicator.innerCommandStarted.isCompleted, isTrue);

    fixture.connector.isDFU = true;
    fixture.appState.changesMade();
    expect(readCardState.mounted, isTrue);
    communicator.completeInnerCommand();
    await tester.idle();

    expect(tester.takeException(), isNull);
    expect(communicator.innerCommandCalls, 1);
    expect(fixture.appState.readCardSession.hfInfo, same(originalInfo));
  });

  testWidgets('foreground page State survives connection changes', (
    tester,
  ) async {
    final fixture = await _ReadCardFixture.mount(tester);
    await fixture.openSavedCards();
    final initialState = tester.state<SavedCardsPageState>(
      find.byType(SavedCardsPage),
    );

    await fixture.connector.performDisconnect();
    await tester.pumpAndSettle();
    expect(
      tester.state<SavedCardsPageState>(find.byType(SavedCardsPage)),
      same(initialState),
    );

    fixture.reconnect();
    await tester.pumpAndSettle();
    expect(
      tester.state<SavedCardsPageState>(find.byType(SavedCardsPage)),
      same(initialState),
    );
  });

  testWidgets('real continuous HF scan executes again while offstage', (
    tester,
  ) async {
    final fixture = await _ReadCardFixture.mount(
      tester,
      communicatorFactory: (logger, connector) =>
          _ContinuousHFCommunicator(logger, port: connector),
    );
    final communicator = fixture.communicator as _ContinuousHFCommunicator;
    final readCardState = await fixture.openReadCard();

    await readCardState.startContinuousHFScan();
    expect(communicator.scanCalls, 1);

    await fixture.openSavedCards();
    await tester.pump(const Duration(seconds: 2));
    await tester.idle();

    expect(communicator.scanCalls, 2);
    expect(readCardState.mounted, isTrue);
    expect(readCardState.isContinuousHFScan, isTrue);
    readCardState.stopContinuousHFScan();
    await tester.pump();
  });

  testWidgets('real continuous LF scan executes again while offstage', (
    tester,
  ) async {
    final fixture = await _ReadCardFixture.mount(
      tester,
      communicatorFactory: (logger, connector) =>
          _ContinuousLFCommunicator(logger, port: connector),
    );
    final communicator = fixture.communicator as _ContinuousLFCommunicator;
    final readCardState = await fixture.openReadCard();

    await readCardState.startContinuousLFScan();
    expect(communicator.readCalls, 1);

    await fixture.openSavedCards();
    await tester.pump(const Duration(seconds: 2));
    await tester.idle();

    expect(communicator.readCalls, 2);
    expect(readCardState.mounted, isTrue);
    expect(readCardState.isContinuousLFScan, isTrue);
    readCardState.stopContinuousLFScan();
    await tester.pump();
  });

  testWidgets(
    'late HF result from a canceled scan cannot stop its replacement',
    (tester) async {
      final fixture = await _ReadCardFixture.mount(
        tester,
        communicatorFactory: (logger, connector) =>
            _SlowContinuousHFCommunicator(logger, port: connector),
      );
      final communicator =
          fixture.communicator as _SlowContinuousHFCommunicator;
      final readCardState = await fixture.openReadCard();

      final canceledScan = readCardState.startContinuousHFScan();
      await tester.pump();
      expect(communicator.scanCalls, 1);

      readCardState.stopContinuousHFScan();
      final replacementScan = readCardState.startContinuousHFScan();
      await tester.pump();
      await replacementScan;
      final replacementInfo = HFCardInfo(uid: 'replacement');
      readCardState.hfInfo = replacementInfo;

      communicator.completeFirstScan(
        CardData(
          uid: Uint8List.fromList([1, 2, 3, 4]),
          sak: 0x00,
          atqa: Uint8List.fromList([0x00, 0x44]),
          ats: Uint8List(0),
        ),
      );
      await canceledScan;
      await tester.pump();

      expect(readCardState.hfInfo, same(replacementInfo));
      expect(readCardState.isContinuousHFScan, isTrue);

      await tester.pump(const Duration(seconds: 2));
      await tester.idle();
      expect(communicator.scanCalls, 2);
      expect(readCardState.isContinuousHFScan, isTrue);
      readCardState.stopContinuousHFScan();
      await tester.pump();
    },
  );

  testWidgets(
    'late LF result from a canceled scan cannot stop its replacement',
    (tester) async {
      final fixture = await _ReadCardFixture.mount(
        tester,
        communicatorFactory: (logger, connector) =>
            _SlowContinuousLFCommunicator(logger, port: connector),
      );
      final communicator =
          fixture.communicator as _SlowContinuousLFCommunicator;
      final readCardState = await fixture.openReadCard();

      final canceledScan = readCardState.startContinuousLFScan();
      await tester.pump();
      expect(communicator.readCalls, 1);

      readCardState.stopContinuousLFScan();
      final replacementScan = readCardState.startContinuousLFScan();
      await tester.pump();
      await replacementScan;
      final replacementInfo = LFCardInfo()
        ..card = EM410XCard.fromUID('AABBCCDDEE');
      readCardState.lfInfo = replacementInfo;

      communicator.completeFirstRead(EM410XCard.fromUID('0102030405'));
      await canceledScan;
      await tester.pump();

      expect(readCardState.lfInfo, same(replacementInfo));
      expect(readCardState.isContinuousLFScan, isTrue);

      await tester.pump(const Duration(seconds: 2));
      await tester.idle();
      expect(communicator.readCalls, 2);
      expect(readCardState.isContinuousLFScan, isTrue);
      readCardState.stopContinuousLFScan();
      await tester.pump();
    },
  );

  testWidgets('continuous HF scan ends on reconnect between ticks', (
    tester,
  ) async {
    final fixture = await _ReadCardFixture.mount(
      tester,
      communicatorFactory: (logger, connector) =>
          _ContinuousHFCommunicator(logger, port: connector),
    );
    final original = fixture.communicator as _ContinuousHFCommunicator;
    final readCardState = await fixture.openReadCard();

    await readCardState.startContinuousHFScan();
    expect(original.scanCalls, 1);

    final replacement =
        _ContinuousHFCommunicator(fixture.logger, port: fixture.connector);
    fixture.appState
      ..communicator = replacement
      ..changesMade();
    await tester.pump(const Duration(seconds: 2));
    await tester.idle();

    expect(replacement.scanCalls, 0);
    expect(readCardState.isContinuousHFScan, isFalse);
  });

  testWidgets('continuous LF scan ends on reconnect between ticks', (
    tester,
  ) async {
    final fixture = await _ReadCardFixture.mount(
      tester,
      communicatorFactory: (logger, connector) =>
          _ContinuousLFCommunicator(logger, port: connector),
    );
    final original = fixture.communicator as _ContinuousLFCommunicator;
    final readCardState = await fixture.openReadCard();

    await readCardState.startContinuousLFScan();
    expect(original.readCalls, 1);

    final replacement =
        _ContinuousLFCommunicator(fixture.logger, port: fixture.connector);
    fixture.appState
      ..communicator = replacement
      ..changesMade();
    await tester.pump(const Duration(seconds: 2));
    await tester.idle();

    expect(replacement.readCalls, 0);
    expect(readCardState.isContinuousLFScan, isFalse);
  });

  testWidgets(
    'continuous HF scan stops when its app-state provider is replaced',
    (tester) async {
      final fixture = await _ReplaceableReadCardFixture.mount(
        tester,
        originalCommunicatorFactory: (logger, connector) =>
            _PendingHFCommunicator(logger, port: connector),
        replacementCommunicatorFactory: (logger, connector) =>
            _ContinuousHFCommunicator(logger, port: connector),
      );
      final originalCommunicator =
          fixture.originalCommunicator as _PendingHFCommunicator;
      final replacementCommunicator =
          fixture.replacementCommunicator as _ContinuousHFCommunicator;
      final readCardState = tester.state<ReadCardPageState>(
        find.byType(ReadCardPage),
      );
      final originalInfo = HFCardInfo(uid: 'original persisted');
      final replacementInfo = HFCardInfo(uid: 'replacement persisted');
      fixture.originalAppState.readCardSession.hfInfo = originalInfo;
      fixture.replacementAppState.readCardSession.hfInfo = replacementInfo;

      final scan = readCardState.startContinuousHFScan();
      await tester.pump();
      expect(originalCommunicator.scanStarted.isCompleted, isTrue);

      fixture.replaceProvider();
      await tester.pump();
      expect(
        tester.state<ReadCardPageState>(find.byType(ReadCardPage)),
        same(readCardState),
      );
      expect(readCardState.isContinuousHFScan, isFalse);

      await tester.pump(const Duration(seconds: 2));
      expect(originalCommunicator.detectCalls, 0);
      expect(replacementCommunicator.scanCalls, 0);

      originalCommunicator.completeScan(
        CardData(
          uid: Uint8List.fromList([1, 2, 3, 4]),
          sak: 0x08,
          atqa: Uint8List.fromList([0x00, 0x04]),
          ats: Uint8List(0),
        ),
      );
      await scan;
      await tester.pump();

      expect(originalCommunicator.detectCalls, 0);
      expect(replacementCommunicator.scanCalls, 0);
      expect(
        fixture.originalAppState.readCardSession.hfInfo,
        same(originalInfo),
      );
      expect(
        fixture.replacementAppState.readCardSession.hfInfo,
        same(replacementInfo),
      );
    },
  );

  testWidgets(
    'continuous LF scan stops when its app-state provider is replaced',
    (tester) async {
      final fixture = await _ReplaceableReadCardFixture.mount(
        tester,
        originalCommunicatorFactory: (logger, connector) =>
            _PendingLFCommunicator(logger, port: connector),
        replacementCommunicatorFactory: (logger, connector) =>
            _ContinuousLFCommunicator(logger, port: connector),
      );
      final originalCommunicator =
          fixture.originalCommunicator as _PendingLFCommunicator;
      final replacementCommunicator =
          fixture.replacementCommunicator as _ContinuousLFCommunicator;
      final readCardState = tester.state<ReadCardPageState>(
        find.byType(ReadCardPage),
      );
      final replacementInfo = LFCardInfo();
      fixture.replacementAppState.readCardSession.lfInfo = replacementInfo;

      final scan = readCardState.startContinuousLFScan();
      await tester.pump();
      expect(originalCommunicator.readStarted.isCompleted, isTrue);
      final originalInfo = fixture.originalAppState.readCardSession.lfInfo;

      fixture.replaceProvider();
      await tester.pump();
      expect(
        tester.state<ReadCardPageState>(find.byType(ReadCardPage)),
        same(readCardState),
      );
      expect(readCardState.isContinuousLFScan, isFalse);

      await tester.pump(const Duration(seconds: 2));
      expect(originalCommunicator.followUpCalls, 0);
      expect(replacementCommunicator.readCalls, 0);

      originalCommunicator.completeRead(EM410XCard.fromUID('0102030405'));
      await scan;
      await tester.pump();

      expect(originalCommunicator.followUpCalls, 0);
      expect(replacementCommunicator.readCalls, 0);
      expect(
        fixture.originalAppState.readCardSession.lfInfo,
        same(originalInfo),
      );
      expect(originalInfo.card, isNull);
      expect(
        fixture.replacementAppState.readCardSession.lfInfo,
        same(replacementInfo),
      );
    },
  );

  testWidgets(
    'slow continuous scan skips overlapping ticks and resumes later',
    (tester) async {
      final fixture = await _ReadCardFixture.mount(
        tester,
        communicatorFactory: (logger, connector) =>
            _SlowContinuousHFCommunicator(logger, port: connector),
      );
      final communicator =
          fixture.communicator as _SlowContinuousHFCommunicator;
      final readCardState = await fixture.openReadCard();

      final initialScan = readCardState.startContinuousHFScan();
      await tester.pump();
      expect(communicator.scanCalls, 1);

      await fixture.openSavedCards();
      await tester.pump(const Duration(seconds: 4));
      await tester.idle();
      expect(communicator.scanCalls, 1);
      expect(readCardState.isContinuousHFScan, isTrue);

      communicator.completeFirstScan();
      await initialScan;
      await tester.pump(const Duration(seconds: 2));
      await tester.idle();

      expect(communicator.scanCalls, 2);
      expect(readCardState.isContinuousHFScan, isTrue);
      readCardState.stopContinuousHFScan();
      await tester.pump();
    },
  );

  testWidgets(
    'slow continuous LF scan skips overlapping ticks and resumes later',
    (tester) async {
      final fixture = await _ReadCardFixture.mount(
        tester,
        communicatorFactory: (logger, connector) =>
            _SlowContinuousLFCommunicator(logger, port: connector),
      );
      final communicator =
          fixture.communicator as _SlowContinuousLFCommunicator;
      final readCardState = await fixture.openReadCard();

      final initialScan = readCardState.startContinuousLFScan();
      await tester.pump();
      expect(communicator.readCalls, 1);

      await fixture.openSavedCards();
      await tester.pump(const Duration(seconds: 4));
      await tester.idle();
      expect(communicator.readCalls, 1);
      expect(readCardState.isContinuousLFScan, isTrue);

      communicator.completeFirstRead();
      await initialScan;
      await tester.pump(const Duration(seconds: 2));
      await tester.idle();

      expect(communicator.readCalls, 2);
      expect(readCardState.isContinuousLFScan, isTrue);
      readCardState.stopContinuousLFScan();
      await tester.pump();
    },
  );

  testWidgets('throwing continuous scan releases RF access without escaping', (
    tester,
  ) async {
    final fixture = await _ReadCardFixture.mount(
      tester,
      communicatorFactory: (logger, connector) =>
          _ThrowingContinuousHFCommunicator(logger, port: connector),
    );
    final readCardState = await fixture.openReadCard();

    await readCardState.startContinuousHFScan();
    await fixture.openSavedCards();
    await tester.pump(const Duration(seconds: 2));
    await tester.idle();

    expect(tester.takeException(), isNull);
    expect(readCardState.isContinuousHFScan, isFalse);
    expect(
      await fixture.appState.rfOperations.runForeground(() async => true),
      isTrue,
    );
  });

  testWidgets(
    'offstage continuous scan yields to Standard preflight and execute',
    (tester) async {
      final targetBlocks = _miniTargetBlocks();
      final fixture = await _ReadCardFixture.mount(
        tester,
        configurePreferences: (preferences) {
          const key = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF];
          preferences.setMifareClassicKeyProfiles([
            MifareClassicKeyProfile(
              id: 'mini-profile',
              name: 'Mini keys',
              cardType: 'mini',
              sectorCount: 5,
              assignments: List.generate(
                5,
                (sector) => MifareClassicKeyAssignment(
                  sector: sector,
                  keyA: Uint8List.fromList(key),
                ),
              ),
            ),
          ]);
          preferences.setCards([
            CardSave(
              id: 'mini-card',
              uid: '01020304',
              name: 'Mini dump',
              tag: TagType.mifareMini,
              extraData: CardSaveExtra(mifareClassicDumpComplete: true),
              data: targetBlocks,
            ),
          ]);
        },
        communicatorFactory: (logger, connector) =>
            _CrossTabMaintenanceCommunicator(
          logger,
          [
            for (var block = 0; block < 20; block++)
              Uint8List.fromList(targetBlocks[block]),
          ]..[1] = Uint8List(16),
          port: connector,
        ),
      );
      final communicator =
          fixture.communicator as _CrossTabMaintenanceCommunicator;
      final readCardState = await fixture.openReadCard();
      final readerModeBaseline = communicator.readerModeCalls;
      final initialScan = readCardState.startContinuousHFScan();
      await tester.pump();
      expect(communicator.readerModeCalls, readerModeBaseline + 1);
      expect(communicator.scanCalls, 1);

      await tester.tap(find.byIcon(Icons.system_update_alt));
      await tester.pumpAndSettle();
      expect(find.byType(ReadCardPage), findsNothing);
      expect(find.byType(ReadCardPage, skipOffstage: false), findsOneWidget);
      await tester.tap(find.text('Standard MIFARE Classic'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select saved card'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mini dump'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select key profile'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mini keys (5 keys)').last);
      await tester.pumpAndSettle();

      communicator.gatePreflight = true;
      await tester.tap(find.text('Run preflight'));
      await tester.pump(const Duration(seconds: 4));
      expect(communicator.readerModeCalls, readerModeBaseline + 1);
      expect(communicator.scanCalls, 1);
      expect(readCardState.isContinuousHFScan, isTrue);

      communicator.completeContinuousScan();
      await initialScan;
      await tester.pump();
      await communicator.preflightStarted.future.timeout(
        const Duration(seconds: 2),
      );
      expect(communicator.readerModeCalls, readerModeBaseline + 2);

      await tester.pump(const Duration(seconds: 4));
      expect(communicator.readerModeCalls, readerModeBaseline + 2);
      expect(readCardState.isContinuousHFScan, isTrue);
      communicator.allowPreflight.complete();
      await tester.pumpAndSettle();
      communicator.gatePreflight = false;
      expect(find.textContaining('Preflight passed'), findsOneWidget);

      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      communicator.gateExecute = true;
      await tester.tap(find.text('Write and verify'));
      await tester.pump();
      await communicator.executeStarted.future.timeout(
        const Duration(seconds: 2),
      );
      expect(communicator.readerModeCalls, readerModeBaseline + 3);

      await tester.pump(const Duration(seconds: 4));
      expect(communicator.readerModeCalls, readerModeBaseline + 3);
      expect(readCardState.isContinuousHFScan, isTrue);
      communicator.allowExecute.complete();
      await tester.pumpAndSettle();

      expect(communicator.writeCalls, 1);
      expect(find.textContaining('Complete: 1 block'), findsOneWidget);
      readCardState.stopContinuousHFScan();
      await tester.pump();
    },
  );

  testWidgets('DFU mode removes the persistent Read Card page', (tester) async {
    final fixture = await _ReadCardFixture.mount(tester);
    final readCardState = await fixture.openReadCard();
    await fixture.openSavedCards();
    expect(readCardState.mounted, isTrue);

    fixture.connector.isDFU = true;
    fixture.appState.changesMade();
    await tester.pump();

    expect(find.byType(ReadCardPage, skipOffstage: false), findsNothing);
    expect(readCardState.mounted, isFalse);
  });
}

typedef _CommunicatorFactory = ChameleonCommunicator Function(
    Logger logger, EmulatorSerial connector);
typedef _ConfigurePreferences = void Function(
    SharedPreferencesProvider preferences);

class _ReadCardFixture {
  _ReadCardFixture({
    required this.tester,
    required this.logger,
    required this.connector,
    required this.appState,
    required this.communicator,
  });

  final WidgetTester tester;
  final Logger logger;
  final EmulatorSerial connector;
  final ChameleonGUIState appState;
  final ChameleonCommunicator communicator;

  static Future<_ReadCardFixture> mount(
    WidgetTester tester, {
    _CommunicatorFactory? communicatorFactory,
    _ConfigurePreferences? configurePreferences,
    Size physicalSize = const Size(3000, 1600),
    bool directReadCard = false,
  }) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/wakelock'),
      (call) async => null,
    );
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    configurePreferences?.call(preferences);
    final logger = Logger(output: MemoryOutput());
    final connector = EmulatorSerial(log: logger)
      ..connected = true
      ..device = ChameleonDevice.ultra
      ..connectionType = ConnectionType.usb;
    final communicator = communicatorFactory?.call(logger, connector) ??
        ChameleonCommunicator(logger, port: connector);
    final appState = ChameleonGUIState(preferences)
      ..log = logger
      ..connector = connector
      ..communicator = communicator;

    tester.view.physicalSize = physicalSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider<ChameleonGUIState>.value(
        value: appState,
        child: directReadCard
            ? MaterialApp(
                locale: preferences.getLocale(),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: const ReadCardPage(),
              )
            : MainPage(sharedPreferencesProvider: preferences),
      ),
    );
    await tester.pump();

    return _ReadCardFixture(
      tester: tester,
      logger: logger,
      connector: connector,
      appState: appState,
      communicator: communicator,
    );
  }

  Future<ReadCardPageState> openReadCard() async {
    if (find.byType(ReadCardPage).evaluate().isNotEmpty) {
      return tester.state<ReadCardPageState>(find.byType(ReadCardPage));
    }
    await tester.tap(find.byIcon(Icons.sensors));
    await tester.pumpAndSettle();
    return tester.state<ReadCardPageState>(find.byType(ReadCardPage));
  }

  Future<void> openSavedCards() async {
    await tester.tap(find.byIcon(Icons.auto_awesome_motion));
    await tester.pumpAndSettle();
  }

  void reconnect() {
    connector
      ..connected = true
      ..device = ChameleonDevice.ultra
      ..connectionType = ConnectionType.usb;
    appState
      ..communicator = ChameleonCommunicator(logger, port: connector)
      ..changesMade();
  }
}

class _ReplaceableReadCardFixture {
  _ReplaceableReadCardFixture({
    required this.hostKey,
    required this.originalAppState,
    required this.originalCommunicator,
    required this.replacementAppState,
    required this.replacementCommunicator,
  });

  final GlobalKey<_ReplaceableReadCardHostState> hostKey;
  final ChameleonGUIState originalAppState;
  final ChameleonCommunicator originalCommunicator;
  final ChameleonGUIState replacementAppState;
  final ChameleonCommunicator replacementCommunicator;

  static Future<_ReplaceableReadCardFixture> mount(
    WidgetTester tester, {
    required _CommunicatorFactory originalCommunicatorFactory,
    required _CommunicatorFactory replacementCommunicatorFactory,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    final logger = Logger(output: MemoryOutput());
    addTearDown(logger.close);

    ChameleonGUIState createAppState(_CommunicatorFactory factory) {
      final connector = EmulatorSerial(log: logger)
        ..connected = true
        ..device = ChameleonDevice.ultra
        ..connectionType = ConnectionType.usb;
      final communicator = factory(logger, connector);
      return ChameleonGUIState(preferences)
        ..log = logger
        ..connector = connector
        ..communicator = communicator;
    }

    final originalAppState = createAppState(originalCommunicatorFactory);
    final replacementAppState = createAppState(replacementCommunicatorFactory);
    final hostKey = GlobalKey<_ReplaceableReadCardHostState>();

    tester.view.physicalSize = const Size(3000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _ReplaceableReadCardHost(
        key: hostKey,
        initialAppState: originalAppState,
        preferences: preferences,
      ),
    );
    await tester.pump();

    return _ReplaceableReadCardFixture(
      hostKey: hostKey,
      originalAppState: originalAppState,
      originalCommunicator: originalAppState.communicator!,
      replacementAppState: replacementAppState,
      replacementCommunicator: replacementAppState.communicator!,
    );
  }

  void replaceProvider() {
    hostKey.currentState!.replaceAppState(replacementAppState);
  }
}

class _ReplaceableReadCardHost extends StatefulWidget {
  const _ReplaceableReadCardHost({
    super.key,
    required this.initialAppState,
    required this.preferences,
  });

  final ChameleonGUIState initialAppState;
  final SharedPreferencesProvider preferences;

  @override
  State<_ReplaceableReadCardHost> createState() =>
      _ReplaceableReadCardHostState();
}

class _ReplaceableReadCardHostState extends State<_ReplaceableReadCardHost> {
  late ChameleonGUIState _appState;

  @override
  void initState() {
    super.initState();
    _appState = widget.initialAppState;
  }

  void replaceAppState(ChameleonGUIState appState) {
    setState(() {
      _appState = appState;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<ChameleonGUIState>.value(
      value: _appState,
      child: MaterialApp(
        locale: widget.preferences.getLocale(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const ReadCardPage(),
      ),
    );
  }
}

List<Uint8List> _miniTargetBlocks() {
  const key = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF];
  const trailer = [
    ...key,
    0xFF,
    0x07,
    0x80,
    0x69,
    ...key,
  ];
  final blocks = List.generate(256, (_) => Uint8List(0));
  for (var block = 0; block < 20; block++) {
    blocks[block] = Uint8List(16);
  }
  blocks[0].setRange(0, 4, [1, 2, 3, 4]);
  blocks[1][0] = 1;
  for (var sector = 0; sector < 5; sector++) {
    blocks[mfClassicGetSectorTrailerBlockBySector(sector)] =
        Uint8List.fromList(trailer);
  }
  return blocks;
}

class _PendingHFCommunicator extends ChameleonCommunicator {
  _PendingHFCommunicator(super.logger, {super.port});

  final Completer<void> scanStarted = Completer<void>();
  final Completer<CardData?> _scanResult = Completer<CardData?>();
  int detectCalls = 0;

  @override
  Future<bool> isReaderDeviceMode() async => true;

  @override
  Future<CardData?> scan14443aTag() {
    scanStarted.complete();
    return _scanResult.future;
  }

  @override
  Future<bool> detectMf1Support() async {
    detectCalls++;
    return false;
  }

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
    if (data.first == _mifareUltralightGetVersionCommand) {
      return Uint8List.fromList([0, 0, 4, 2, 1, 0, 0x0F, 3]);
    }
    if (data.first == _mifareUltralightReadSignatureCommand) {
      return Uint8List(32);
    }
    return Uint8List(0);
  }

  void completeScan(CardData? card) => _scanResult.complete(card);
}

class _PendingLFCommunicator extends ChameleonCommunicator {
  _PendingLFCommunicator(super.logger, {super.port});

  final Completer<void> readStarted = Completer<void>();
  final Completer<EM410XCard?> _readResult = Completer<EM410XCard?>();
  int followUpCalls = 0;

  @override
  Future<bool> isReaderDeviceMode() async => true;

  @override
  Future<EM410XCard?> readEM410X() {
    readStarted.complete();
    return _readResult.future;
  }

  @override
  Future<HIDCard?> readHIDProx() async {
    followUpCalls++;
    return null;
  }

  @override
  Future<VikingCard?> readViking() async {
    followUpCalls++;
    return null;
  }

  @override
  Future<PacCard?> readPac() async {
    followUpCalls++;
    return null;
  }

  @override
  Future<IoProxCard?> readIoProx() async {
    followUpCalls++;
    return null;
  }

  void completeRead(EM410XCard? card) => _readResult.complete(card);
}

class _ContinuousHFCommunicator extends ChameleonCommunicator {
  _ContinuousHFCommunicator(super.logger, {super.port});

  int scanCalls = 0;

  @override
  Future<bool> isReaderDeviceMode() async => true;

  @override
  Future<CardData?> scan14443aTag() async {
    scanCalls++;
    return null;
  }
}

class _ContinuousBothCommunicator extends _ContinuousLFCommunicator {
  _ContinuousBothCommunicator(super.logger, {super.port});

  int scanCalls = 0;

  @override
  Future<CardData?> scan14443aTag() async {
    scanCalls++;
    return null;
  }
}

class _SlowContinuousHFCommunicator extends _PendingHFCommunicator {
  _SlowContinuousHFCommunicator(super.logger, {super.port});

  final Completer<CardData?> _firstScan = Completer<CardData?>();
  int scanCalls = 0;

  @override
  Future<CardData?> scan14443aTag() {
    scanCalls++;
    if (scanCalls == 1) {
      return _firstScan.future;
    }
    return Future.value(null);
  }

  void completeFirstScan([CardData? card]) => _firstScan.complete(card);
}

class _ThrowingContinuousHFCommunicator extends ChameleonCommunicator {
  _ThrowingContinuousHFCommunicator(super.logger, {super.port});

  int scanCalls = 0;

  @override
  Future<bool> isReaderDeviceMode() async => true;

  @override
  Future<CardData?> scan14443aTag() async {
    scanCalls++;
    if (scanCalls > 1) {
      throw StateError('scan failed');
    }
    return null;
  }
}

class _SlowContinuousLFCommunicator extends ChameleonCommunicator {
  _SlowContinuousLFCommunicator(super.logger, {super.port});

  final Completer<EM410XCard?> _firstRead = Completer<EM410XCard?>();
  int readCalls = 0;

  @override
  Future<bool> isReaderDeviceMode() async => true;

  @override
  Future<EM410XCard?> readEM410X() {
    readCalls++;
    if (readCalls == 1) {
      return _firstRead.future;
    }
    return Future.value(null);
  }

  @override
  Future<HIDCard?> readHIDProx() async => null;

  @override
  Future<VikingCard?> readViking() async => null;

  @override
  Future<PacCard?> readPac() async => null;

  @override
  Future<IoProxCard?> readIoProx() async => null;

  void completeFirstRead([EM410XCard? card]) => _firstRead.complete(card);
}

class _CrossTabMaintenanceCommunicator extends ChameleonCommunicator {
  _CrossTabMaintenanceCommunicator(super.logger, this.blocks, {super.port});

  final List<Uint8List> blocks;
  final Completer<CardData?> _continuousScan = Completer<CardData?>();
  final Completer<void> preflightStarted = Completer<void>();
  final Completer<void> allowPreflight = Completer<void>();
  final Completer<void> executeStarted = Completer<void>();
  final Completer<void> allowExecute = Completer<void>();
  int readerModeCalls = 0;
  int scanCalls = 0;
  int writeCalls = 0;
  bool gatePreflight = false;
  bool gateExecute = false;

  @override
  Future<bool> isReaderDeviceMode() async {
    readerModeCalls++;
    if (gatePreflight && !preflightStarted.isCompleted) {
      preflightStarted.complete();
      await allowPreflight.future;
    } else if (gateExecute && !executeStarted.isCompleted) {
      executeStarted.complete();
      await allowExecute.future;
    }
    return true;
  }

  @override
  Future<CardData?> scan14443aTag() {
    scanCalls++;
    if (scanCalls == 1) {
      return _continuousScan.future;
    }
    return Future.value(CardData(
      uid: Uint8List.fromList([1, 2, 3, 4]),
      sak: 0x08,
      atqa: Uint8List.fromList([0x00, 0x04]),
      ats: Uint8List(0),
    ));
  }

  @override
  Future<bool> detectMf1Support() async => true;

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
  }) async =>
      Uint8List(0);

  @override
  Future<ChameleonMessage> mf1AuthResult(
    int block,
    int keyType,
    Uint8List key,
  ) async =>
      ChameleonMessage(command: 0, status: 0, data: Uint8List(0));

  @override
  Future<ChameleonMessage> mf1ReadBlockResult(
    int block,
    int keyType,
    Uint8List key,
  ) async =>
      ChameleonMessage(
        command: 0,
        status: 0,
        data: Uint8List.fromList(blocks[block]),
      );

  @override
  Future<ChameleonMessage> mf1WriteBlockResult(
    int block,
    int keyType,
    Uint8List key,
    Uint8List data,
  ) async {
    writeCalls++;
    blocks[block] = Uint8List.fromList(data);
    return ChameleonMessage(command: 0, status: 0, data: Uint8List(0));
  }

  void completeContinuousScan() => _continuousScan.complete(null);
}

class _ContinuousLFCommunicator extends ChameleonCommunicator {
  _ContinuousLFCommunicator(super.logger, {super.port});

  int readCalls = 0;

  @override
  Future<bool> isReaderDeviceMode() async => true;

  @override
  Future<EM410XCard?> readEM410X() async {
    readCalls++;
    return null;
  }

  @override
  Future<HIDCard?> readHIDProx() async => null;

  @override
  Future<VikingCard?> readViking() async => null;

  @override
  Future<PacCard?> readPac() async => null;

  @override
  Future<IoProxCard?> readIoProx() async => null;
}

class _InnerClassicBoundaryCommunicator extends ChameleonCommunicator {
  _InnerClassicBoundaryCommunicator(super.logger, {super.port});

  final Completer<void> innerCommandStarted = Completer<void>();
  final Completer<Uint8List> _innerCommandResult = Completer<Uint8List>();
  int innerCommandCalls = 0;
  int followUpCalls = 0;

  @override
  Future<bool> isReaderDeviceMode() async => true;

  @override
  Future<CardData?> scan14443aTag() async => CardData(
        uid: Uint8List.fromList([1, 2, 3, 4]),
        sak: 0x08,
        atqa: Uint8List.fromList([0x00, 0x04]),
        ats: Uint8List(0),
      );

  @override
  Future<bool> detectMf1Support() async => true;

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
    innerCommandCalls++;
    if (!innerCommandStarted.isCompleted) {
      innerCommandStarted.complete();
      return _innerCommandResult.future;
    }
    followUpCalls++;
    return Future.value(Uint8List(0));
  }

  @override
  Future<bool> mf1Auth(int block, int keyType, Uint8List key) async {
    followUpCalls++;
    return false;
  }

  @override
  Future<NTLevel> getMf1NTLevel() async {
    followUpCalls++;
    return NTLevel.unknown;
  }

  void completeInnerCommand() => _innerCommandResult.complete(Uint8List(0));
}

class _InnerUltralightBoundaryCommunicator extends ChameleonCommunicator {
  _InnerUltralightBoundaryCommunicator(super.logger, {super.port});

  final Completer<void> innerCommandStarted = Completer<void>();
  final Completer<Uint8List> _innerCommandResult = Completer<Uint8List>();
  int innerCommandCalls = 0;

  @override
  Future<bool> isReaderDeviceMode() async => true;

  @override
  Future<CardData?> scan14443aTag() async => CardData(
        uid: Uint8List.fromList([1, 2, 3, 4]),
        sak: 0x00,
        atqa: Uint8List.fromList([0x00, 0x44]),
        ats: Uint8List(0),
      );

  @override
  Future<bool> detectMf1Support() async => false;

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
    innerCommandCalls++;
    if (!innerCommandStarted.isCompleted) {
      innerCommandStarted.complete();
      return _innerCommandResult.future;
    }
    return Future.value(Uint8List(0));
  }

  void completeInnerCommand() => _innerCommandResult.complete(
        Uint8List.fromList([0, 0, 4, 2, 1, 0, 0x0F, 3]),
      );
}
