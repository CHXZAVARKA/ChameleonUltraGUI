import 'package:chameleonultragui/status/connected_device_status.dart';
import 'package:flutter/material.dart';

class SlotChanger extends StatelessWidget {
  const SlotChanger({super.key, required this.status});

  final ConnectedDeviceStatus status;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: status,
      builder: (context, _) {
        final slots = status.snapshot.slots;
        final activeSlot = slots.activeSlot.value;
        final slotIcons = List.generate(8, (index) {
          if (index == activeSlot) {
            return const Icon(Icons.circle_outlined, color: Colors.red);
          }
          if (slots.slots[index].isConfigured) {
            return const Icon(Icons.circle);
          }
          return const Icon(Icons.circle_outlined);
        });

        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              onPressed: activeSlot != null && activeSlot > 0
                  ? () => status.activateSlot(activeSlot - 1)
                  : null,
              icon: const Icon(Icons.arrow_back),
            ),
            ...slotIcons,
            IconButton(
              onPressed: activeSlot != null && activeSlot < 7
                  ? () => status.activateSlot(activeSlot + 1)
                  : null,
              icon: const Icon(Icons.arrow_forward),
            ),
          ],
        );
      },
    );
  }
}
