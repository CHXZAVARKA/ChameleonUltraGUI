import 'package:chameleonultragui/gui/component/error_page.dart';
import 'package:chameleonultragui/helpers/connected_device_session.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:chameleonultragui/main.dart';

class SlotChanger extends StatefulWidget {
  const SlotChanger({super.key});

  @override
  SlotChangerState createState() => SlotChangerState();
}

class SlotChangerState extends State<SlotChanger> {
  var selectedSlot = 1;

  @override
  void initState() {
    super.initState();
  }

  Future<List<Icon>> getFutureData() async {
    var appState = context.read<ChameleonGUIState>();
    final result = await appState.runSessionBoundForeground((session) async {
      List<SlotTypes> usedSlots;
      try {
        usedSlots = await session.communicator.getSlotTagTypes();
      } catch (_) {
        usedSlots = [];
      }
      if (!mounted || !session.isCurrent) return null;

      var activeSlot = 1;
      try {
        activeSlot = await session.communicator.getActiveSlot() + 1;
      } catch (_) {}
      if (!mounted || !session.isCurrent) return null;

      return (usedSlots: usedSlots, activeSlot: activeSlot);
    });
    final session = result.session;
    final data = result.value;
    if (!result.executed ||
        session == null ||
        data == null ||
        !mounted ||
        !session.isCurrent) {
      return [const Icon(Icons.warning)];
    }

    selectedSlot = data.activeSlot;
    return getSlotIcons(data.usedSlots);
  }

  List<Icon> getSlotIcons(List<SlotTypes> usedSlots) {
    List<Icon> icons = [];

    if (usedSlots.isEmpty) {
      return [const Icon(Icons.warning)];
    }

    for (int i = 0; i < 8; i++) {
      if (i == selectedSlot - 1) {
        icons.add(const Icon(
          Icons.circle_outlined,
          color: Colors.red,
        ));
      } else if (usedSlots[i].notMatch()) {
        icons.add(const Icon(Icons.circle));
      } else {
        icons.add(const Icon(Icons.circle_outlined));
      }
    }
    return icons;
  }

  Future<void> _activateSlot(int slot) async {
    final appState = context.read<ChameleonGUIState>();
    await appState.runSessionBoundForeground((session) async {
      if (!mounted || !session.isCurrent) {
        return;
      }
      await session.communicator.activateSlot(slot);
      if (!mounted || !session.isCurrent) {
        return;
      }
      setState(() {});
      appState.changesMade();
    });
  }

  List<Icon> presold = [
    const Icon(Icons.circle_outlined),
    const Icon(Icons.circle_outlined),
    const Icon(Icons.circle_outlined),
    const Icon(Icons.circle_outlined),
    const Icon(Icons.circle_outlined),
    const Icon(Icons.circle_outlined),
    const Icon(Icons.circle_outlined),
    const Icon(Icons.circle_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    var appState = context.read<ChameleonGUIState>();

    return FutureBuilder(
        future: getFutureData(),
        builder: (BuildContext context, AsyncSnapshot snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  onPressed: () async {},
                  icon: const Icon(Icons.arrow_back),
                ),
                ...presold,
                IconButton(
                  onPressed: () async {},
                  icon: const Icon(Icons.arrow_forward),
                ),
              ],
            );
          } else if (snapshot.hasError) {
            appState.connector!.performDisconnect();
            return ErrorPage(errorMessage: snapshot.error.toString());
          } else {
            final slotIcons = snapshot.data;
            presold = slotIcons;

            return Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  onPressed: () async {
                    if (selectedSlot > 1) {
                      await _activateSlot(selectedSlot - 2);
                    }
                  },
                  icon: const Icon(Icons.arrow_back),
                ),
                ...slotIcons,
                IconButton(
                  onPressed: () async {
                    if (selectedSlot < 8) {
                      await _activateSlot(selectedSlot);
                    }
                  },
                  icon: const Icon(Icons.arrow_forward),
                ),
              ],
            );
          }
        });
  }
}
