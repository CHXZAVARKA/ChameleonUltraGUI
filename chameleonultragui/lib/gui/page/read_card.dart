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
  Timer? hfScanTimer;
  Timer? lfScanTimer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _appState = Provider.of<ChameleonGUIState>(context, listen: false);
    _session = _appState.readCardSession;
    mfcInfo.recovery?.update = updateMifareClassicRecovery;
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
      ConnectedDeviceSession session,
      {bool scanFinished = false}) {
    if (!mounted || !session.isCurrent) {
      return false;
    }

    setState(() {
      hfInfo = info.$1;
      mfcInfo = info.$2;
      mfuInfo = info.$3;
      if (scanFinished) {
        scanInProgress = false;
      }
    });
    return true;
  }

  Future<bool> _readAndCommitHFInfoUnderLease({
    required ConnectedDeviceSession session,
    bool scanFinished = false,
  }) async {
    if (!mounted || !session.isCurrent) {
      return false;
    }
    final info = await readHFInfo(
      context,
      updateMifareClassicRecovery,
      canContinue: () => mounted && session.isCurrent,
    );
    return _commitHFInfo(
      info,
      session,
      scanFinished: scanFinished,
    );
  }

  Future<bool> _readAndCommitHFInfo({bool scanFinished = false}) async {
    final result = await _appState.runSessionBoundForeground(
      (session) => _readAndCommitHFInfoUnderLease(
        session: session,
        scanFinished: scanFinished,
      ),
    );
    return result.executed && result.value == true;
  }

  Future<bool> _readLFInfoUnderLease(ConnectedDeviceSession session) async {
    if (!mounted || !session.isCurrent) {
      return false;
    }
    final communicator = session.communicator;

    setState(() {
      lfInfo = LFCardInfo();
    });

    if (!await communicator.isReaderDeviceMode()) {
      if (!mounted || !session.isCurrent) {
        return false;
      }
      await communicator.setReaderDeviceMode(true);
    }
    if (!mounted || !session.isCurrent) {
      return false;
    }

    LFCard? card = await communicator.readEM410X();
    if (!mounted || !session.isCurrent) {
      return false;
    }
    if (card == null) {
      card = await communicator.readHIDProx();
      if (!mounted || !session.isCurrent) {
        return false;
      }
    }
    if (card == null) {
      card = await communicator.readViking();
      if (!mounted || !session.isCurrent) {
        return false;
      }
    }
    if (card == null) {
      card = await communicator.readPac();
      if (!mounted || !session.isCurrent) {
        return false;
      }
    }
    if (card == null) {
      card = await communicator.readIoProx();
      if (!mounted || !session.isCurrent) {
        return false;
      }
    }

    if (!mounted || !session.isCurrent) {
      return false;
    }
    if (card != null) {
      setState(() {
        lfInfo.card = card;
        scanInProgress = false;
      });
    } else {
      setState(() {
        lfInfo.cardExist = false;
        scanInProgress = false;
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

  Future<void> _runContinuousHFScanTick() async {
    final session = ConnectedDeviceSession.capture(_appState);
    if (session == null) {
      stopContinuousHFScan();
      return;
    }
    try {
      final result = await _appState.rfOperations.tryRunBackground(
        () => _readAndCommitHFInfoUnderLease(session: session),
      );
      if (!result.acquired) {
        return;
      }
      if (result.value != true) {
        stopContinuousHFScan();
        return;
      }
      if (hfInfo.cardExist && hfInfo.uid.isNotEmpty) {
        stopContinuousHFScan();
      }
    } catch (error, stackTrace) {
      (_appState.log ?? _appState.communicator?.log)?.e(
        'Continuous HF scan failed',
        error: error,
        stackTrace: stackTrace,
      );
      stopContinuousHFScan();
    }
  }

  Future<void> _runContinuousLFScanTick() async {
    final session = ConnectedDeviceSession.capture(_appState);
    if (session == null) {
      stopContinuousLFScan();
      return;
    }
    try {
      final result = await _appState.rfOperations.tryRunBackground(
        () => _readLFInfoUnderLease(session),
      );
      if (!result.acquired) {
        return;
      }
      if (result.value != true) {
        stopContinuousLFScan();
        return;
      }
      if (lfInfo.cardExist && lfInfo.card != null) {
        stopContinuousLFScan();
      }
    } catch (error, stackTrace) {
      (_appState.log ?? _appState.communicator?.log)?.e(
        'Continuous LF scan failed',
        error: error,
        stackTrace: stackTrace,
      );
      stopContinuousLFScan();
    }
  }

  Future<void> startContinuousHFScan() async {
    if (isContinuousHFScan) return;

    setState(() {
      isContinuousHFScan = true;
    });

    const scanInterval = Duration(seconds: 2);
    const maxDuration = Duration(minutes: 1);

    DateTime startTime = DateTime.now();

    hfScanTimer = Timer.periodic(scanInterval, (timer) {
      if (DateTime.now().difference(startTime) > maxDuration || !mounted) {
        stopContinuousHFScan();
        return;
      }

      unawaited(_runContinuousHFScanTick());
    });

    await _runContinuousHFScanTick();
  }

  void stopContinuousHFScan() {
    if (hfScanTimer != null) {
      hfScanTimer?.cancel();
      hfScanTimer = null;

      if (mounted) {
        setState(() {
          isContinuousHFScan = false;
        });
      }
    }
  }

  Future<void> startContinuousLFScan() async {
    if (isContinuousLFScan) return;

    setState(() {
      isContinuousLFScan = true;
    });

    const scanInterval = Duration(seconds: 2);
    const maxDuration = Duration(minutes: 1);

    DateTime startTime = DateTime.now();

    lfScanTimer = Timer.periodic(scanInterval, (timer) {
      if (DateTime.now().difference(startTime) > maxDuration || !mounted) {
        stopContinuousLFScan();
        return;
      }

      unawaited(_runContinuousLFScanTick());
    });

    await _runContinuousLFScanTick();
  }

  void stopContinuousLFScan() {
    if (lfScanTimer != null) {
      lfScanTimer?.cancel();
      lfScanTimer = null;

      if (mounted) {
        setState(() {
          isContinuousLFScan = false;
        });
      }
    }
  }

  @override
  void dispose() {
    hfScanTimer?.cancel();
    hfScanTimer = null;
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
                                              setState(() {
                                                scanInProgress = true;
                                              });
                                              await _readAndCommitHFInfo(
                                                scanFinished: true,
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
                                              setState(() {
                                                scanInProgress = true;
                                              });
                                              await readLFInfo();
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
