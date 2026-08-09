import 'package:chameleonultragui/gui/component/card_button.dart';
import 'package:chameleonultragui/gui/component/mifare/classic.dart';
import 'package:chameleonultragui/gui/component/error_message.dart';
import 'package:chameleonultragui/gui/component/mifare/ultralight.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/connected_device_session.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_ultralight/general.dart';
import 'package:chameleonultragui/helpers/read_card_session.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'dart:async';

// Localizations
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';

class ReadCardPage extends StatefulWidget {
  const ReadCardPage({super.key});

  @override
  ReadCardPageState createState() => ReadCardPageState();
}

class _ContinuousScanToken {
  const _ContinuousScanToken(this.session);

  final ConnectedDeviceSession session;
}

class ReadCardPageState extends State<ReadCardPage> {
  late ChameleonGUIState _appState;
  late ReadCardSession _session;

  String get dumpName => _session.dumpName;
  set dumpName(String value) => _session.dumpName = value;

  HFCardInfo get hfInfo => _session.hfInfo;
  set hfInfo(HFCardInfo value) => _session.hfInfo = value;

  LFCardInfo get lfInfo => _session.lfInfo;
  set lfInfo(LFCardInfo value) => _session.lfInfo = value;

  MifareClassicInfo get mfcInfo => _session.mfcInfo;
  set mfcInfo(MifareClassicInfo value) => _session.mfcInfo = value;

  MifareUltralightInfo get mfuInfo => _session.mfuInfo;
  set mfuInfo(MifareUltralightInfo value) => _session.mfuInfo = value;

  bool isContinuousHFScan = false;
  bool isContinuousLFScan = false;
  bool scanInProgress = false;
  ConnectedDeviceSession? _manualReadSession;
  _ContinuousScanToken? _continuousHFScan;
  _ContinuousScanToken? _continuousLFScan;
  Timer? hfScanTimer;
  Timer? lfScanTimer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _appState = Provider.of<ChameleonGUIState>(context, listen: false);
    _session = _appState.readCardSession;
    mfcInfo.recovery?.update = updateMifareClassicRecovery;

    final activeSession = _manualReadSession;
    if (activeSession != null &&
        (!identical(activeSession.appState, _appState) ||
            !activeSession.isCurrent)) {
      _manualReadSession = null;
      scanInProgress = false;
    }
  }

  void updateMifareClassicRecovery() {
    if (!mounted) {
      return;
    }
    setState(() {
      mfcInfo.recovery = mfcInfo.recovery;
    });
  }

  void updateMifareClassicInfo() {
    if (!mounted) {
      return;
    }
    setState(() {
      mfcInfo = mfcInfo;
    });
  }

  bool _commitHFInfo((HFCardInfo, MifareClassicInfo, MifareUltralightInfo) info,
      ConnectedDeviceSession session) {
    if (!mounted || !session.isCurrent) {
      return false;
    }

    setState(() {
      hfInfo = info.$1;
      mfcInfo = info.$2;
      mfuInfo = info.$3;
    });
    return true;
  }

  Future<bool> _readAndCommitHFInfoUnderLease({
    required ConnectedDeviceSession session,
    bool Function()? canContinue,
  }) async {
    bool mayContinue() =>
        mounted && session.isCurrent && (canContinue?.call() ?? true);
    if (!mayContinue()) {
      return false;
    }
    final info = await readHFInfo(
      context,
      updateMifareClassicRecovery,
      canContinue: mayContinue,
    );
    if (!mayContinue()) {
      return false;
    }
    return _commitHFInfo(
      info,
      session,
    );
  }

  Future<bool> _readAndCommitHFInfo() async {
    final result = await _appState.runSessionBoundForeground(
      (session) => _readAndCommitHFInfoUnderLease(
        session: session,
      ),
    );
    return result.executed && result.value == true;
  }

  Future<void> _runManualRead(Future<bool> Function() read) async {
    final session = ConnectedDeviceSession.capture(_appState);
    if (!mounted || scanInProgress || session == null) {
      return;
    }

    setState(() {
      _manualReadSession = session;
      scanInProgress = true;
    });

    try {
      await read();
    } finally {
      if (identical(_manualReadSession, session)) {
        _manualReadSession = null;
        if (mounted) {
          setState(() {
            scanInProgress = false;
          });
        }
      }
    }
  }

  Future<bool> _readLFInfoUnderLease(
    ConnectedDeviceSession session, {
    bool Function()? canContinue,
  }) async {
    bool mayContinue() =>
        mounted && session.isCurrent && (canContinue?.call() ?? true);
    if (!mayContinue()) {
      return false;
    }
    final communicator = session.communicator;

    setState(() {
      lfInfo = LFCardInfo();
    });

    if (!await communicator.isReaderDeviceMode()) {
      if (!mayContinue()) {
        return false;
      }
      await communicator.setReaderDeviceMode(true);
    }
    if (!mayContinue()) {
      return false;
    }

    LFCard? card = await communicator.readEM410X();
    if (!mayContinue()) {
      return false;
    }
    if (card == null) {
      card = await communicator.readHIDProx();
      if (!mayContinue()) {
        return false;
      }
    }
    if (card == null) {
      card = await communicator.readViking();
      if (!mayContinue()) {
        return false;
      }
    }
    if (card == null) {
      card = await communicator.readPac();
      if (!mayContinue()) {
        return false;
      }
    }
    if (card == null) {
      card = await communicator.readIoProx();
      if (!mayContinue()) {
        return false;
      }
    }

    if (!mayContinue()) {
      return false;
    }
    if (card != null) {
      setState(() {
        lfInfo.card = card;
      });
    } else {
      setState(() {
        lfInfo.cardExist = false;
      });
    }
    return true;
  }

  Future<bool> readLFInfo() async {
    final result = await _appState.runSessionBoundForeground(
      _readLFInfoUnderLease,
    );
    return result.executed && result.value == true;
  }

  bool _ownsContinuousScan(
    _ContinuousScanToken token,
    _ContinuousScanToken? currentToken,
    bool active,
  ) =>
      active && identical(token, currentToken);

  bool _canContinueContinuousScan(
    _ContinuousScanToken token,
    _ContinuousScanToken? currentToken,
    bool active,
  ) =>
      mounted &&
      _ownsContinuousScan(token, currentToken, active) &&
      identical(token.session.appState, _appState) &&
      token.session.isCurrent;

  bool _ownsContinuousHFScan(_ContinuousScanToken token) =>
      _ownsContinuousScan(token, _continuousHFScan, isContinuousHFScan);

  bool _canContinueHFScan(_ContinuousScanToken token) =>
      _canContinueContinuousScan(
        token,
        _continuousHFScan,
        isContinuousHFScan,
      );

  Future<void> _runContinuousHFScanTick(_ContinuousScanToken token) async {
    if (!_canContinueHFScan(token)) {
      _stopContinuousHFScan(token);
      return;
    }
    final session = token.session;
    try {
      final result = await _appState.rfOperations.tryRunBackground(
        () => _readAndCommitHFInfoUnderLease(
          session: session,
          canContinue: () => _canContinueHFScan(token),
        ),
      );
      if (!_ownsContinuousHFScan(token)) {
        return;
      }
      if (!_canContinueHFScan(token)) {
        _stopContinuousHFScan(token);
        return;
      }
      if (!result.acquired) {
        return;
      }
      if (result.value != true) {
        _stopContinuousHFScan(token);
        return;
      }
      if (hfInfo.cardExist && hfInfo.uid.isNotEmpty) {
        _stopContinuousHFScan(token);
      }
    } catch (error, stackTrace) {
      (_appState.log ?? session.communicator.log).e(
        'Continuous HF scan failed',
        error: error,
        stackTrace: stackTrace,
      );
      _stopContinuousHFScan(token);
    }
  }

  bool _ownsContinuousLFScan(_ContinuousScanToken token) =>
      _ownsContinuousScan(token, _continuousLFScan, isContinuousLFScan);

  bool _canContinueLFScan(_ContinuousScanToken token) =>
      _canContinueContinuousScan(
        token,
        _continuousLFScan,
        isContinuousLFScan,
      );

  Future<void> _runContinuousLFScanTick(_ContinuousScanToken token) async {
    if (!_canContinueLFScan(token)) {
      _stopContinuousLFScan(token);
      return;
    }
    final session = token.session;
    try {
      final result = await _appState.rfOperations.tryRunBackground(
        () => _readLFInfoUnderLease(
          session,
          canContinue: () => _canContinueLFScan(token),
        ),
      );
      if (!_ownsContinuousLFScan(token)) {
        return;
      }
      if (!_canContinueLFScan(token)) {
        _stopContinuousLFScan(token);
        return;
      }
      if (!result.acquired) {
        return;
      }
      if (result.value != true) {
        _stopContinuousLFScan(token);
        return;
      }
      if (lfInfo.cardExist && lfInfo.card != null) {
        _stopContinuousLFScan(token);
      }
    } catch (error, stackTrace) {
      (_appState.log ?? session.communicator.log).e(
        'Continuous LF scan failed',
        error: error,
        stackTrace: stackTrace,
      );
      _stopContinuousLFScan(token);
    }
  }

  Future<void> startContinuousHFScan() async {
    if (isContinuousHFScan) return;

    final session = ConnectedDeviceSession.capture(_appState);
    if (session == null) {
      return;
    }
    final token = _ContinuousScanToken(session);
    _continuousHFScan = token;

    setState(() {
      isContinuousHFScan = true;
    });

    const scanInterval = Duration(seconds: 2);
    const maxDuration = Duration(minutes: 1);

    DateTime startTime = DateTime.now();

    hfScanTimer = Timer.periodic(scanInterval, (timer) {
      if (!_canContinueHFScan(token) ||
          DateTime.now().difference(startTime) > maxDuration) {
        _stopContinuousHFScan(token);
        return;
      }

      unawaited(_runContinuousHFScanTick(token));
    });

    await _runContinuousHFScanTick(token);
  }

  void stopContinuousHFScan() {
    final token = _continuousHFScan;
    if (token != null) {
      _stopContinuousHFScan(token);
    }
  }

  void _stopContinuousHFScan(_ContinuousScanToken token) {
    if (!_ownsContinuousHFScan(token)) {
      return;
    }

    hfScanTimer?.cancel();
    hfScanTimer = null;
    _continuousHFScan = null;
    if (mounted) {
      setState(() {
        isContinuousHFScan = false;
      });
    } else {
      isContinuousHFScan = false;
    }
  }

  Future<void> startContinuousLFScan() async {
    if (isContinuousLFScan) return;

    final session = ConnectedDeviceSession.capture(_appState);
    if (session == null) {
      return;
    }
    final token = _ContinuousScanToken(session);
    _continuousLFScan = token;

    setState(() {
      isContinuousLFScan = true;
    });

    const scanInterval = Duration(seconds: 2);
    const maxDuration = Duration(minutes: 1);

    DateTime startTime = DateTime.now();

    lfScanTimer = Timer.periodic(scanInterval, (timer) {
      if (!_canContinueLFScan(token) ||
          DateTime.now().difference(startTime) > maxDuration) {
        _stopContinuousLFScan(token);
        return;
      }

      unawaited(_runContinuousLFScanTick(token));
    });

    await _runContinuousLFScanTick(token);
  }

  void stopContinuousLFScan() {
    final token = _continuousLFScan;
    if (token != null) {
      _stopContinuousLFScan(token);
    }
  }

  void _stopContinuousLFScan(_ContinuousScanToken token) {
    if (!_ownsContinuousLFScan(token)) {
      return;
    }

    lfScanTimer?.cancel();
    lfScanTimer = null;
    _continuousLFScan = null;
    if (mounted) {
      setState(() {
        isContinuousLFScan = false;
      });
    } else {
      isContinuousLFScan = false;
    }
  }

  @override
  void dispose() {
    _manualReadSession = null;
    _continuousHFScan = null;
    isContinuousHFScan = false;
    hfScanTimer?.cancel();
    hfScanTimer = null;
    _continuousLFScan = null;
    isContinuousLFScan = false;
    lfScanTimer?.cancel();
    lfScanTimer = null;
    super.dispose();
  }

  Future<void> saveHFCard() async {
    var appState = Provider.of<ChameleonGUIState>(context, listen: false);
    var localizations = AppLocalizations.of(context)!;

    var tags = appState.sharedPreferencesProvider.getCards();
    tags.add(CardSave(
      uid: hfInfo.uid,
      sak: hexToBytes(hfInfo.sak)[0],
      atqa: hexToBytes(hfInfo.atqa),
      name: dumpName,
      tag: hfInfo.type != TagType.unknown ? hfInfo.type : TagType.mifare1K,
      data: [],
      ats: (hfInfo.ats != localizations.no)
          ? hexToBytes(hfInfo.ats)
          : Uint8List(0),
      extraData: CardSaveExtra(
        ultralightSignature: mfuInfo.signature,
        ultralightVersion: mfuInfo.version,
        ultralightCounters: [],
      ),
    ));

    appState.sharedPreferencesProvider.setCards(tags);
  }

  Future<void> saveLFCard() async {
    var appState = Provider.of<ChameleonGUIState>(context, listen: false);

    var tags = appState.sharedPreferencesProvider.getCards();
    tags.add(CardSave(
        uid: lfInfo.card.toString(), name: dumpName, tag: lfInfo.card!.type));
    appState.sharedPreferencesProvider.setCards(tags);
  }

  Widget buildFieldRow(String label, String value, double fontSize) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Text(
        '$label: $value',
        textAlign: (MediaQuery.of(context).size.width < 800)
            ? TextAlign.left
            : TextAlign.center,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: fontSize,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    var localizations = AppLocalizations.of(context)!;
    final isSmallScreen = screenSize.width < 800;

    double fieldFontSize = isSmallScreen ? 16 : 20;

    var appState = context.watch<ChameleonGUIState>();

    return Scaffold(
      appBar: AppBar(
        title: Text(localizations.read_card),
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            Center(
              child: Card(
                elevation: 3,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        localizations.hf_tag_info,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      buildFieldRow(
                          localizations.uid, hfInfo.uid, fieldFontSize),
                      buildFieldRow(
                          localizations.sak, hfInfo.sak, fieldFontSize),
                      buildFieldRow(
                          localizations.atqa, hfInfo.atqa, fieldFontSize),
                      buildFieldRow(
                          localizations.ats, hfInfo.ats, fieldFontSize),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '${localizations.card_tech}: ${hfInfo.tech}',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: fieldFontSize),
                          ),
                          if (hfInfo.uid.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            IconButton(
                              onPressed: () {
                                showDialog(
                                  context: context,
                                  builder: (BuildContext context) {
                                    return AlertDialog(
                                      title: Text(
                                          localizations.override_card_type),
                                      content: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            localizations
                                                .override_card_type_description,
                                            style:
                                                const TextStyle(fontSize: 14),
                                          ),
                                          const SizedBox(height: 16),
                                          DropdownButton<TagType?>(
                                            isExpanded: true,
                                            value: hfInfo.type,
                                            onChanged:
                                                (TagType? newValue) async {
                                              setState(() {
                                                hfInfo.type = newValue!;
                                                hfInfo.tech =
                                                    chameleonTagToString(
                                                        newValue,
                                                        localizations);
                                              });

                                              if (isMifareClassic(newValue!)) {
                                                final pendingInfo =
                                                    MifareClassicInfo(
                                                        state: mfcInfo.state);
                                                final result = await _appState
                                                    .runSessionBoundForeground(
                                                        (session) async {
                                                  if (!session.isCurrent ||
                                                      !mounted) {
                                                    return null;
                                                  }
                                                  return performMifareClassicScan(
                                                    session.communicator,
                                                    pendingInfo,
                                                    context,
                                                    updateMifareClassicRecovery,
                                                    override: newValue,
                                                    canContinue: () =>
                                                        mounted &&
                                                        session.isCurrent,
                                                  );
                                                });
                                                final info = result.value;
                                                if (info == null) {
                                                  return;
                                                }
                                                final session = result.session!;
                                                if (!mounted ||
                                                    !session.isCurrent) {
                                                  return;
                                                }
                                                setState(() {
                                                  mfcInfo = info.$2;
                                                });
                                              } else if (isMifareUltralight(
                                                  newValue)) {
                                                final pendingInfo =
                                                    MifareUltralightInfo()
                                                      ..version =
                                                          mfuInfo.version
                                                      ..signature =
                                                          mfuInfo.signature;
                                                final result = await _appState
                                                    .runSessionBoundForeground(
                                                        (session) async {
                                                  if (!mounted ||
                                                      !session.isCurrent) {
                                                    return null;
                                                  }
                                                  return performMifareUltralightScan(
                                                    session.communicator,
                                                    pendingInfo,
                                                    override: newValue,
                                                    canContinue: () =>
                                                        mounted &&
                                                        session.isCurrent,
                                                  );
                                                });
                                                final info = result.value;
                                                if (info == null) {
                                                  return;
                                                }
                                                final session = result.session!;
                                                if (!mounted ||
                                                    !session.isCurrent) {
                                                  return;
                                                }
                                                setState(() {
                                                  mfuInfo = info.$2;
                                                });
                                              }

                                              if (context.mounted) {
                                                Navigator.of(context).pop();
                                              }
                                            },
                                            items: [
                                              ...[
                                                ...getTagTypesByFrequency(
                                                    TagFrequency.hf),
                                                TagType.unknown
                                              ].map((TagType tagType) {
                                                return DropdownMenuItem<
                                                    TagType?>(
                                                  value: tagType,
                                                  child: Text(
                                                      chameleonTagToString(
                                                          tagType,
                                                          localizations)),
                                                );
                                              }),
                                            ],
                                          ),
                                        ],
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.of(context).pop(),
                                          child: Text(localizations.cancel),
                                        ),
                                      ],
                                    );
                                  },
                                );
                              },
                              icon: const Icon(Icons.edit),
                              iconSize: 20,
                              padding: const EdgeInsets.all(4),
                              constraints: const BoxConstraints(
                                minWidth: 32,
                                minHeight: 32,
                              ),
                              tooltip: localizations.override_card_type,
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (isMifareClassic(hfInfo.type)) ...[
                        if (mfcInfo.ntLevel != null)
                          buildFieldRow(
                              localizations.prng_type,
                              mfClassicGetPrngType(
                                  mfcInfo.ntLevel!, localizations),
                              fieldFontSize),
                        if (mfcInfo.hasBackdoor != null)
                          buildFieldRow(
                              localizations.has_backdoor_support,
                              mfcInfo.hasBackdoor!
                                  ? localizations.yes
                                  : localizations.no,
                              fieldFontSize),
                        const SizedBox(height: 16),
                      ],
                      isSmallScreen
                          ? Column(
                              children: [
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton(
                                    onPressed: scanInProgress
                                        ? null
                                        : () async {
                                            if (appState.connector!.device ==
                                                ChameleonDevice.ultra) {
                                              await _runManualRead(
                                                _readAndCommitHFInfo,
                                              );
                                            } else if (appState
                                                    .connector!.device ==
                                                ChameleonDevice.lite) {
                                              showDialog<String>(
                                                context: context,
                                                builder:
                                                    (BuildContext context) =>
                                                        AlertDialog(
                                                  title: Text(localizations
                                                      .no_supported),
                                                  content: Text(
                                                      localizations
                                                          .lite_no_read,
                                                      style: const TextStyle(
                                                          fontWeight:
                                                              FontWeight.bold)),
                                                  actions: <Widget>[
                                                    TextButton(
                                                      onPressed: () =>
                                                          Navigator.pop(context,
                                                              localizations.ok),
                                                      child: Text(
                                                          localizations.ok),
                                                    ),
                                                  ],
                                                ),
                                              );
                                            } else {
                                              appState.changesMade();
                                            }
                                          },
                                    style: customCardButtonStyle(appState),
                                    child: Text(localizations.read),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton(
                                    onPressed: isContinuousHFScan
                                        ? () => stopContinuousHFScan()
                                        : () async {
                                            if (appState.connector!.device ==
                                                ChameleonDevice.ultra) {
                                              await startContinuousHFScan();
                                            } else if (appState
                                                    .connector!.device ==
                                                ChameleonDevice.lite) {
                                              showDialog<String>(
                                                context: context,
                                                builder:
                                                    (BuildContext context) =>
                                                        AlertDialog(
                                                  title: Text(localizations
                                                      .no_supported),
                                                  content: Text(
                                                      localizations
                                                          .lite_no_read,
                                                      style: const TextStyle(
                                                          fontWeight:
                                                              FontWeight.bold)),
                                                  actions: <Widget>[
                                                    TextButton(
                                                      onPressed: () =>
                                                          Navigator.pop(context,
                                                              localizations.ok),
                                                      child: Text(
                                                          localizations.ok),
                                                    ),
                                                  ],
                                                ),
                                              );
                                            } else {
                                              appState.changesMade();
                                            }
                                          },
                                    style: customCardButtonStyle(appState),
                                    child: Text(isContinuousHFScan
                                        ? localizations.cancel
                                        : localizations.continuous_scan),
                                  ),
                                ),
                              ],
                            )
                          : Row(
                              children: [
                                Expanded(
                                  child: ElevatedButton(
                                    onPressed: () async {
                                      if (appState.connector!.device ==
                                          ChameleonDevice.ultra) {
                                        await _readAndCommitHFInfo();
                                      } else if (appState.connector!.device ==
                                          ChameleonDevice.lite) {
                                        showDialog<String>(
                                          context: context,
                                          builder: (BuildContext context) =>
                                              AlertDialog(
                                            title: Text(
                                                localizations.no_supported),
                                            content: Text(
                                                localizations.lite_no_read,
                                                style: const TextStyle(
                                                    fontWeight:
                                                        FontWeight.bold)),
                                            actions: <Widget>[
                                              TextButton(
                                                onPressed: () => Navigator.pop(
                                                    context, localizations.ok),
                                                child: Text(localizations.ok),
                                              ),
                                            ],
                                          ),
                                        );
                                      } else {
                                        appState.changesMade();
                                      }
                                    },
                                    style: customCardButtonStyle(appState),
                                    child: Text(localizations.read),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: ElevatedButton(
                                    onPressed: isContinuousHFScan
                                        ? () => stopContinuousHFScan()
                                        : () async {
                                            if (appState.connector!.device ==
                                                ChameleonDevice.ultra) {
                                              await startContinuousHFScan();
                                            } else if (appState
                                                    .connector!.device ==
                                                ChameleonDevice.lite) {
                                              showDialog<String>(
                                                context: context,
                                                builder:
                                                    (BuildContext context) =>
                                                        AlertDialog(
                                                  title: Text(localizations
                                                      .no_supported),
                                                  content: Text(
                                                      localizations
                                                          .lite_no_read,
                                                      style: const TextStyle(
                                                          fontWeight:
                                                              FontWeight.bold)),
                                                  actions: <Widget>[
                                                    TextButton(
                                                      onPressed: () =>
                                                          Navigator.pop(context,
                                                              localizations.ok),
                                                      child: Text(
                                                          localizations.ok),
                                                    ),
                                                  ],
                                                ),
                                              );
                                            } else {
                                              appState.changesMade();
                                            }
                                          },
                                    style: customCardButtonStyle(appState),
                                    child: Text(isContinuousHFScan
                                        ? localizations.cancel
                                        : localizations.continuous_scan),
                                  ),
                                ),
                              ],
                            ),
                      if (!hfInfo.cardExist) ...[
                        const SizedBox(height: 16),
                        ErrorMessage(errorMessage: localizations.no_card_found)
                      ],
                      if (hfInfo.uid != "") ...[
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: () async {
                            await showDialog(
                              context: context,
                              builder: (BuildContext context) {
                                return AlertDialog(
                                  title: Text(localizations.enter_name_of_card),
                                  content: TextField(
                                    onChanged: (value) {
                                      setState(() {
                                        dumpName = value;
                                      });
                                    },
                                  ),
                                  actions: [
                                    ElevatedButton(
                                      onPressed: () async {
                                        await saveHFCard();
                                        if (context.mounted) {
                                          Navigator.pop(context);
                                        }
                                      },
                                      child: Text(localizations.ok),
                                    ),
                                    ElevatedButton(
                                      onPressed: () {
                                        Navigator.pop(
                                            context); // Close the modal without saving
                                      },
                                      child: Text(localizations.cancel),
                                    ),
                                  ],
                                );
                              },
                            );
                          },
                          style: customCardButtonStyle(appState),
                          child: Text(localizations.save_only_uid),
                        ),
                      ],
                      if (isMifareClassic(hfInfo.type))
                        MifareClassicHelper(mfcInfo: mfcInfo, hfInfo: hfInfo),
                      if (isMifareUltralight(hfInfo.type))
                        MifareUltralightHelper(hfInfo: hfInfo)
                    ],
                  ),
                ),
              ),
            ),
            Center(
              child: Card(
                elevation: 3,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        localizations.lf_tag_info,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      buildFieldRow(
                          localizations.uid,
                          lfInfo.card != null
                              ? lfInfo.card!.toViewableString()
                              : '',
                          fieldFontSize),
                      const SizedBox(height: 16),
                      Text(
                        '${localizations.card_tech}: ${(lfInfo.card != null ? chameleonTagToString(lfInfo.card!.type, localizations) : '')}',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: fieldFontSize),
                      ),
                      const SizedBox(height: 16),
                      isSmallScreen
                          ? Column(
                              children: [
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton(
                                    onPressed: scanInProgress
                                        ? null
                                        : () async {
                                            if (appState.connector!.device ==
                                                ChameleonDevice.ultra) {
                                              await _runManualRead(readLFInfo);
                                            } else if (appState
                                                    .connector!.device ==
                                                ChameleonDevice.lite) {
                                              showDialog<String>(
                                                context: context,
                                                builder:
                                                    (BuildContext context) =>
                                                        AlertDialog(
                                                  title: Text(localizations
                                                      .no_supported),
                                                  content: Text(
                                                      localizations
                                                          .lite_no_read,
                                                      style: const TextStyle(
                                                          fontWeight:
                                                              FontWeight.bold)),
                                                  actions: <Widget>[
                                                    TextButton(
                                                      onPressed: () =>
                                                          Navigator.pop(context,
                                                              localizations.ok),
                                                      child: Text(
                                                          localizations.ok),
                                                    ),
                                                  ],
                                                ),
                                              );
                                            } else {
                                              appState.changesMade();
                                            }
                                          },
                                    style: customCardButtonStyle(appState),
                                    child: Text(localizations.read),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton(
                                    onPressed: isContinuousLFScan
                                        ? () => stopContinuousLFScan()
                                        : () async {
                                            if (appState.connector!.device ==
                                                ChameleonDevice.ultra) {
                                              await startContinuousLFScan();
                                            } else if (appState
                                                    .connector!.device ==
                                                ChameleonDevice.lite) {
                                              showDialog<String>(
                                                context: context,
                                                builder:
                                                    (BuildContext context) =>
                                                        AlertDialog(
                                                  title: Text(localizations
                                                      .no_supported),
                                                  content: Text(
                                                      localizations
                                                          .lite_no_read,
                                                      style: const TextStyle(
                                                          fontWeight:
                                                              FontWeight.bold)),
                                                  actions: <Widget>[
                                                    TextButton(
                                                      onPressed: () =>
                                                          Navigator.pop(context,
                                                              localizations.ok),
                                                      child: Text(
                                                          localizations.ok),
                                                    ),
                                                  ],
                                                ),
                                              );
                                            } else {
                                              appState.changesMade();
                                            }
                                          },
                                    style: customCardButtonStyle(appState),
                                    child: Text(isContinuousLFScan
                                        ? localizations.cancel
                                        : localizations.continuous_scan),
                                  ),
                                ),
                              ],
                            )
                          : Row(
                              children: [
                                Expanded(
                                  child: ElevatedButton(
                                    onPressed: () async {
                                      if (appState.connector!.device ==
                                          ChameleonDevice.ultra) {
                                        await readLFInfo();
                                      } else if (appState.connector!.device ==
                                          ChameleonDevice.lite) {
                                        showDialog<String>(
                                          context: context,
                                          builder: (BuildContext context) =>
                                              AlertDialog(
                                            title: Text(
                                                localizations.no_supported),
                                            content: Text(
                                                localizations.lite_no_read,
                                                style: const TextStyle(
                                                    fontWeight:
                                                        FontWeight.bold)),
                                            actions: <Widget>[
                                              TextButton(
                                                onPressed: () => Navigator.pop(
                                                    context, localizations.ok),
                                                child: Text(localizations.ok),
                                              ),
                                            ],
                                          ),
                                        );
                                      } else {
                                        appState.changesMade();
                                      }
                                    },
                                    style: customCardButtonStyle(appState),
                                    child: Text(localizations.read),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: ElevatedButton(
                                    onPressed: isContinuousLFScan
                                        ? () => stopContinuousLFScan()
                                        : () async {
                                            if (appState.connector!.device ==
                                                ChameleonDevice.ultra) {
                                              await startContinuousLFScan();
                                            } else if (appState
                                                    .connector!.device ==
                                                ChameleonDevice.lite) {
                                              showDialog<String>(
                                                context: context,
                                                builder:
                                                    (BuildContext context) =>
                                                        AlertDialog(
                                                  title: Text(localizations
                                                      .no_supported),
                                                  content: Text(
                                                      localizations
                                                          .lite_no_read,
                                                      style: const TextStyle(
                                                          fontWeight:
                                                              FontWeight.bold)),
                                                  actions: <Widget>[
                                                    TextButton(
                                                      onPressed: () =>
                                                          Navigator.pop(context,
                                                              localizations.ok),
                                                      child: Text(
                                                          localizations.ok),
                                                    ),
                                                  ],
                                                ),
                                              );
                                            } else {
                                              appState.changesMade();
                                            }
                                          },
                                    style: customCardButtonStyle(appState),
                                    child: Text(isContinuousLFScan
                                        ? localizations.cancel
                                        : localizations.continuous_scan),
                                  ),
                                ),
                              ],
                            ),
                      if (!lfInfo.cardExist) ...[
                        const SizedBox(height: 16),
                        ErrorMessage(errorMessage: localizations.no_card_found)
                      ],
                      if (lfInfo.card != null) ...[
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: () async {
                            await showDialog(
                              context: context,
                              builder: (BuildContext context) {
                                return AlertDialog(
                                  title: Text(localizations.enter_name_of_card),
                                  content: TextField(
                                    onChanged: (value) {
                                      setState(() {
                                        dumpName = value;
                                      });
                                    },
                                  ),
                                  actions: [
                                    ElevatedButton(
                                      onPressed: () async {
                                        await saveLFCard();
                                        if (context.mounted) {
                                          Navigator.pop(context);
                                        }
                                      },
                                      child: Text(localizations.ok),
                                    ),
                                    ElevatedButton(
                                      onPressed: () {
                                        Navigator.pop(
                                            context); // Close the modal without saving
                                      },
                                      child: Text(localizations.cancel),
                                    ),
                                  ],
                                );
                              },
                            );
                          },
                          style: customCardButtonStyle(appState),
                          child: Text(localizations.save),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
