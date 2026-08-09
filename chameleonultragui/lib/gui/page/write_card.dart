import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/gui/component/card_list.dart';
import 'package:chameleonultragui/gui/component/mifare/standard_write.dart';
import 'package:chameleonultragui/helpers/connected_device_session.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/write.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

// Localizations
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';

class WriteCardPage extends StatefulWidget {
  const WriteCardPage({super.key});

  @override
  WriteCardPageState createState() => WriteCardPageState();
}

class WriteCardPageState extends State<WriteCardPage> {
  _WriteCardMode _mode = _WriteCardMode.magic;
  bool _standardWriteBusy = false;
  int step = 0;
  int progress = -1;
  bool written = false;
  CardSave? card;
  AbstractWriteHelper? baseHelper;
  AbstractWriteHelper? helper;

  Future<SessionBoundRfResult<T?>> _runHelperPreflight<T>(
    ChameleonGUIState appState,
    AbstractWriteHelper selectedHelper,
    Future<T> Function(AbstractWriteHelper helper) operation,
  ) {
    return appState.runSessionBoundForegroundCatching<T?>((session) async {
      if (!mounted ||
          !identical(selectedHelper.communicator, session.communicator)) {
        return null;
      }
      selectedHelper.setOperationContinuation(
        () => mounted && session.isCurrent,
      );
      if (!selectedHelper.operationCanContinue) return null;

      final value = await operation(selectedHelper);
      return selectedHelper.operationCanContinue ? value : null;
    });
  }

  Future<String?> cardSelectDialog(BuildContext context) {
    var appState = context.read<ChameleonGUIState>();
    var tags = appState.sharedPreferencesProvider.getCards();

    tags.sort((a, b) => a.name.compareTo(b.name));

    return showSearch<String>(
      context: context,
      delegate: CardSearchDelegate(cards: tags, onTap: onTap),
    );
  }

  Future<void> onTap(CardSave selectedCard, dynamic close,
      AppLocalizations localizations) async {
    var appState = Provider.of<ChameleonGUIState>(context, listen: false);
    final communicator = appState.communicator;
    if (communicator == null) return;
    final selectedBaseHelper = AbstractWriteHelper.getClassByCardType(
      selectedCard.tag,
      appState,
      updateState,
      localizations,
      operationCanContinue: () =>
          appState.hasConnectedCommunicator(communicator),
    );

    final selectedHelper = selectedBaseHelper?.getAvailableMethods()[0];
    setState(() {
      card = selectedCard;
      baseHelper = selectedBaseHelper;
      helper = selectedHelper;
    });

    if (selectedHelper != null) {
      final result = await _runHelperPreflight<bool>(
        appState,
        selectedHelper,
        (helper) async {
          await helper.getCardType();
          return true;
        },
      );
      if (result.error != null) {
        appState.log?.e('Failed to probe selected card: ${result.error}');
      }
      if (!mounted ||
          result.value != true ||
          !identical(card, selectedCard) ||
          !identical(helper, selectedHelper)) {
        return;
      }
    }

    if (!mounted) return;
    close(context, selectedCard.name);
  }

  Future<void> detectMagicType() async {
    var appState = Provider.of<ChameleonGUIState>(context, listen: false);
    final selectedBaseHelper = baseHelper;
    final selectedCard = card;
    if (selectedBaseHelper == null || selectedCard == null) return;
    final availableMethods = selectedBaseHelper.getAvailableMethods();

    final result = await appState.runSessionBoundForegroundCatching<
        ({bool completed, AbstractWriteHelper? helper})>((session) async {
      bool canContinue() => mounted && session.isCurrent;
      if (!canContinue() ||
          !identical(selectedBaseHelper.communicator, session.communicator)) {
        return (completed: false, helper: null);
      }

      if (!await session.communicator.isReaderDeviceMode()) {
        if (!canContinue()) return (completed: false, helper: null);
        await session.communicator.setReaderDeviceMode(true);
      }
      if (!canContinue()) return (completed: false, helper: null);

      for (final magicHelper in availableMethods) {
        if (!identical(magicHelper.communicator, session.communicator)) {
          return (completed: false, helper: null);
        }
        magicHelper.setOperationContinuation(canContinue);
        if (!magicHelper.operationCanContinue) {
          return (completed: false, helper: null);
        }
        if (!await magicHelper.isMagic(selectedCard)) {
          if (!magicHelper.operationCanContinue) {
            return (completed: false, helper: null);
          }
          continue;
        }
        if (!magicHelper.operationCanContinue) {
          return (completed: false, helper: null);
        }

        try {
          await magicHelper.getCardType();
        } catch (_) {
          if (!magicHelper.operationCanContinue) {
            return (completed: false, helper: null);
          }
          await magicHelper.getCardType();
        }
        if (!magicHelper.operationCanContinue) {
          return (completed: false, helper: null);
        }
        return (completed: true, helper: magicHelper);
      }

      return (completed: true, helper: null);
    });
    if (result.error != null) {
      appState.log?.e('Failed to detect Magic card type: ${result.error}');
    }
    if (!mounted ||
        result.error != null ||
        result.value?.completed != true ||
        !identical(baseHelper, selectedBaseHelper) ||
        !identical(card, selectedCard)) {
      return;
    }

    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final localizations = AppLocalizations.of(context)!;
    final detectedHelper = result.value!.helper;
    if (detectedHelper != null) {
      setState(() {
        helper = detectedHelper;
      });
      appState.log?.i("Detected Magic card type: ${detectedHelper.name}");
      scaffoldMessenger.hideCurrentSnackBar();
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text(
              '${localizations.detected_magic_card_type}: ${detectedHelper.name}'),
          action: SnackBarAction(
            label: localizations.close,
            onPressed: () {},
          ),
        ),
      );
      return;
    }

    scaffoldMessenger.showSnackBar(
      SnackBar(
        content: Text(localizations.failed_to_detect_magic_card_type),
        action: SnackBarAction(
          label: localizations.close,
          onPressed: () {},
        ),
      ),
    );
  }

  void updateState() {
    setState(() {
      helper = helper;
    });
  }

  void updateProgress(int writeProgress) {
    setState(() {
      progress = writeProgress;
    });
  }

  Future<void> writeCard() async {
    var appState = Provider.of<ChameleonGUIState>(context, listen: false);
    var scaffoldMessenger = ScaffoldMessenger.of(context);
    var localizations = AppLocalizations.of(context)!;
    SnackBar snackBar;
    updateProgress(0);
    final selectedHelper = helper;
    final selectedCard = card;

    final result = await appState.runSessionBoundForegroundCatching<bool>(
      (session) async {
        if (selectedHelper == null ||
            selectedCard == null ||
            !identical(selectedHelper.communicator, session.communicator)) {
          return false;
        }
        selectedHelper.setOperationContinuation(
          () => mounted && session.isCurrent,
        );
        if (!selectedHelper.operationCanContinue) return false;

        if (!await session.communicator.isReaderDeviceMode()) {
          if (!selectedHelper.operationCanContinue) return false;
          await session.communicator.setReaderDeviceMode(true);
        }
        if (!selectedHelper.operationCanContinue) return false;

        return selectedHelper.writeData(selectedCard, (writeProgress) {
          if (selectedHelper.operationCanContinue) {
            updateProgress(writeProgress);
          }
        });
      },
    );
    if (result.error != null) {
      appState.log?.e('Failed to write card: ${result.error}');
    }
    if (!mounted) return;

    if (result.executed && result.error == null && result.value == true) {
      snackBar = SnackBar(
        content: Text(localizations.magic_success_write),
        action: SnackBarAction(
          label: localizations.close,
          onPressed: () {},
        ),
      );
    } else {
      snackBar = SnackBar(
        content: Text(localizations.magic_failed_write),
        action: SnackBarAction(
          label: localizations.close,
          onPressed: () {},
        ),
      );
    }

    scaffoldMessenger.hideCurrentSnackBar();
    scaffoldMessenger.showSnackBar(snackBar);

    setState(() {
      written = true;
    });

    updateProgress(-1);
  }

  void onStepContinue() async {
    var localizations = AppLocalizations.of(context)!;
    var scaffoldMessenger = ScaffoldMessenger.of(context);
    var appState = Provider.of<ChameleonGUIState>(context, listen: false);

    if (appState.connector!.device == ChameleonDevice.lite) {
      showDialog<String>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: Text(localizations.no_supported),
          content: Text(localizations.lite_no_read,
              style: const TextStyle(fontWeight: FontWeight.bold)),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, localizations.ok),
              child: Text(localizations.ok),
            ),
          ],
        ),
      );

      return;
    }

    if (step != 2) {
      if (step == 1) {
        await helper?.reset();
      }
      setState(() {
        step++;
      });
    } else if (helper != null && helper!.isReady() && progress == -1) {
      SnackBar snackBar;
      updateProgress(0);
      final selectedHelper = helper!;
      final selectedCard = card!;
      final result = await _runHelperPreflight<bool>(
        appState,
        selectedHelper,
        (helper) => helper.isCompatible(selectedCard),
      );
      if (result.error != null) {
        appState.log?.e('Failed to check card compatibility: ${result.error}');
      }
      if (!mounted ||
          result.error != null ||
          result.value == null ||
          !identical(helper, selectedHelper) ||
          !identical(card, selectedCard)) {
        if (mounted) updateProgress(-1);
        return;
      }

      if (!result.value!) {
        snackBar = SnackBar(
          content: Text(localizations.magic_incompatible_card),
          action: SnackBarAction(
            label: localizations.continue_anyway,
            onPressed: () async {
              await writeCard();
            },
          ),
        );

        scaffoldMessenger.hideCurrentSnackBar();
        scaffoldMessenger.showSnackBar(snackBar);
      } else {
        await writeCard();
      }

      updateProgress(-1);
    }
  }

  void onStepBack() async {
    setState(() {
      written = false;
      step--;
    });

    if (step == 1) {
      await helper?.reset();
    }
  }

  void onStepReset() async {
    setState(() {
      written = false;
      step = 0;
    });
  }

  List<Widget> createButtonsForStep(ControlsDetails details, int step) {
    var localizations = AppLocalizations.of(context)!;
    List<Widget> widgets = [];

    if (written) {
      widgets.add(TextButton(
        onPressed: (progress == -1) ? onStepContinue : null,
        child: Text(localizations.write_again),
      ));

      widgets.add(TextButton(
        onPressed: (progress == -1) ? onStepReset : null,
        child: Text(localizations.reset),
      ));
    } else {
      if (step == 0 || step == 1) {
        widgets.add(TextButton(
          onPressed:
              (step == 0 && card == null || step == 1 && baseHelper == null)
                  ? null
                  : onStepContinue,
          child: Text(localizations.next),
        ));
      }

      if (step == 2) {
        widgets.add(TextButton(
          onPressed: (helper != null && helper!.isReady() && progress == -1)
              ? onStepContinue
              : null,
          child: Text(localizations.write_data_to_magic_card),
        ));
      }

      if (step != 0) {
        widgets.add(TextButton(
          onPressed: onStepBack,
          child: Text(localizations.back),
        ));
      }
    }

    return widgets;
  }

  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    var localizations = AppLocalizations.of(context)!;
    var typeLocalization = {
      'gen1': localizations.gen1,
      'gen2': localizations.gen2,
      'gen3': localizations.gen3,
      't55xx': localizations.t55xx,
    };

    return Scaffold(
      appBar: AppBar(
        title: Text(localizations.write_card),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: SegmentedButton<_WriteCardMode>(
              segments: [
                ButtonSegment(
                  value: _WriteCardMode.magic,
                  icon: const Icon(Icons.auto_fix_high),
                  label: Text(localizations.mifare_classic_magic_card_mode),
                ),
                ButtonSegment(
                  value: _WriteCardMode.standard,
                  icon: const Icon(Icons.credit_card),
                  label: Text(localizations.mifare_classic_standard_card_mode),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: _standardWriteBusy || progress != -1
                  ? null
                  : (selection) {
                      setState(() => _mode = selection.first);
                    },
            ),
          ),
          Expanded(
            child: _mode == _WriteCardMode.standard
                ? StandardMifareClassicWritePanel(
                    onBusyChanged: (busy) {
                      if (mounted) {
                        setState(() => _standardWriteBusy = busy);
                      }
                    },
                  )
                : SingleChildScrollView(
                    child: Center(
                      child: Stepper(
                        physics: const ClampingScrollPhysics(),
                        controlsBuilder:
                            (BuildContext context, ControlsDetails details) {
                          return Column(children: [
                            const SizedBox(height: 8),
                            Row(
                              children: createButtonsForStep(details, step),
                            )
                          ]);
                        },
                        currentStep: step,
                        steps: [
                          Step(
                            title:
                                Text(localizations.select_saved_card_to_write),
                            content: Card(
                              child: ListTile(
                                title: Row(children: [
                                  FilterChip(
                                    onSelected: (bool selected) {
                                      cardSelectDialog(context);
                                    },
                                    avatar: (card != null)
                                        ? CircleAvatar(
                                            backgroundColor: Colors.transparent,
                                            child: Icon(
                                                (chameleonTagToFrequency(
                                                            card!.tag) ==
                                                        TagFrequency.hf)
                                                    ? Icons.credit_card
                                                    : Icons.wifi,
                                                color: card!.color),
                                          )
                                        : null,
                                    label: Text((card != null)
                                        ? card!.name
                                        : localizations.select_saved_card),
                                  )
                                ]),
                              ),
                            ),
                            isActive: step >= 1,
                          ),
                          Step(
                            title: Text(localizations.select_magic_card),
                            content: Card(
                              child: ListTile(
                                title: (baseHelper != null)
                                    ? Wrap(
                                        direction: Axis.horizontal,
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        children: <Widget>[
                                            DropdownButton<AbstractWriteHelper>(
                                              value: helper,
                                              items: baseHelper!
                                                  .getAvailableMethods()
                                                  .map<
                                                          DropdownMenuItem<
                                                              AbstractWriteHelper>>(
                                                      (AbstractWriteHelper
                                                          helperClass) {
                                                return DropdownMenuItem<
                                                    AbstractWriteHelper>(
                                                  value: helperClass,
                                                  child: Text(typeLocalization[
                                                      helperClass.name]!),
                                                );
                                              }).toList(),
                                              onChanged: (AbstractWriteHelper?
                                                  helperClass) {
                                                setState(() {
                                                  helper = helperClass;
                                                });
                                              },
                                            ),
                                            const SizedBox(width: 8),
                                            if (baseHelper!.autoDetect)
                                              TextButton(
                                                onPressed: () async {
                                                  await detectMagicType();
                                                },
                                                child: Text(localizations
                                                    .auto_detect_magic_card),
                                              )
                                          ])
                                    : Text(localizations
                                        .writing_is_not_yet_supported),
                              ),
                            ),
                            isActive: step >= 2,
                          ),
                          Step(
                            title: Text(localizations.write_data_to_magic_card),
                            content: Card(
                              child: ListTile(
                                title: (progress == -1)
                                    ? (helper != null && helper!.isReady())
                                        ? (helper != null &&
                                                helper!
                                                    .getFailedBlocks()
                                                    .isNotEmpty)
                                            ? Text(
                                                "${localizations.otp_magic_warning(localizations.write_data_to_magic_card)} ${localizations.some_blocks_failed_to_write}: ${helper!.getFailedBlocks().join(", ")}")
                                            : Column(children: [
                                                Text(localizations
                                                    .otp_magic_warning(localizations
                                                        .write_data_to_magic_card)),
                                                const SizedBox(height: 8),
                                                Text(
                                                    localizations
                                                        .keep_stable_warning,
                                                    style: const TextStyle(
                                                        color: Colors.orange,
                                                        fontWeight:
                                                            FontWeight.bold))
                                              ])
                                        : (helper != null &&
                                                helper!.writeWidgetSupported())
                                            ? helper!.getWriteWidget(
                                                context, setState)
                                            : Text(localizations.error)
                                    : LinearProgressIndicator(
                                        value: progress.toDouble() / 100),
                              ),
                            ),
                            isActive: step >= 3,
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

enum _WriteCardMode { magic, standard }
