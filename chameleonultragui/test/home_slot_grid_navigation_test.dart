import 'package:chameleonultragui/gui/component/home_slot_grid_navigation.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  void expectTarget(
    int index,
    HomeSlotGridNavigationAction action,
    int? expected, {
    SlotLayout layout = SlotLayout.eightAcross,
    TextDirection textDirection = TextDirection.ltr,
  }) {
    expect(
      HomeSlotGridNavigation.target(
        index: index,
        layout: layout,
        textDirection: textDirection,
        action: action,
      ),
      expected,
    );
  }

  group('activation navigation', () {
    test('wraps through all slots in the eight-across layout', () {
      expectTarget(0, HomeSlotGridNavigationAction.activateLeft, 7);
      expectTarget(0, HomeSlotGridNavigationAction.activateUp, 7);
      expectTarget(7, HomeSlotGridNavigationAction.activateRight, 0);
      expectTarget(7, HomeSlotGridNavigationAction.activateDown, 0);
    });

    test('moves vertically by rows in the two-by-four layout', () {
      expectTarget(0, HomeSlotGridNavigationAction.activateUp, 4,
          layout: SlotLayout.twoByFour);
      expectTarget(2, HomeSlotGridNavigationAction.activateDown, 6,
          layout: SlotLayout.twoByFour);
      expectTarget(0, HomeSlotGridNavigationAction.activateLeft, 7,
          layout: SlotLayout.twoByFour);
    });
  });

  group('bounded reorder navigation', () {
    test('stops at row edges and keeps vertical neighbors in two-by-four', () {
      expectTarget(3, HomeSlotGridNavigationAction.reorderRight, null,
          layout: SlotLayout.twoByFour);
      expectTarget(3, HomeSlotGridNavigationAction.reorderDown, 7,
          layout: SlotLayout.twoByFour);
      expectTarget(4, HomeSlotGridNavigationAction.reorderUp, 0,
          layout: SlotLayout.twoByFour);
    });

    test('left and right follow visual RTL geometry', () {
      expectTarget(0, HomeSlotGridNavigationAction.reorderLeft, 1,
          textDirection: TextDirection.rtl);
      expectTarget(0, HomeSlotGridNavigationAction.reorderRight, null,
          textDirection: TextDirection.rtl);
      expectTarget(3, HomeSlotGridNavigationAction.reorderLeft, null,
          layout: SlotLayout.twoByFour, textDirection: TextDirection.rtl);
    });
  });

  test('semantics before and after never cross a visible row', () {
    expectTarget(0, HomeSlotGridNavigationAction.moveBefore, null);
    expectTarget(0, HomeSlotGridNavigationAction.moveAfter, 1);
    expectTarget(3, HomeSlotGridNavigationAction.moveAfter, null,
        layout: SlotLayout.twoByFour, textDirection: TextDirection.rtl);
    expectTarget(4, HomeSlotGridNavigationAction.moveBefore, null,
        layout: SlotLayout.twoByFour);
  });
}
