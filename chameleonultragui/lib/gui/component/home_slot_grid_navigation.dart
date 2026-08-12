import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/widgets.dart';

/// A keyboard or semantics navigation request within the eight-slot grid.
enum HomeSlotGridNavigationAction {
  activateLeft,
  activateRight,
  activateUp,
  activateDown,
  reorderLeft,
  reorderRight,
  reorderUp,
  reorderDown,
  moveBefore,
  moveAfter,
}

/// Resolves slot-grid navigation without depending on widget state.
///
/// Activation wraps around the complete set of slots. Reordering is bounded by
/// the visible row and follows visual left/right direction in RTL layouts.
abstract final class HomeSlotGridNavigation {
  static const _slotCount = 8;

  static int? target({
    required int index,
    required SlotLayout layout,
    required TextDirection textDirection,
    required HomeSlotGridNavigationAction action,
  }) {
    assert(index >= 0 && index < _slotCount);
    final columns = layout == SlotLayout.twoByFour ? 4 : _slotCount;
    final column = index % columns;
    final before = column > 0 ? index - 1 : null;
    final after = column < columns - 1 ? index + 1 : null;
    final visualLeft = textDirection == TextDirection.ltr ? before : after;
    final visualRight = textDirection == TextDirection.ltr ? after : before;

    return switch (action) {
      HomeSlotGridNavigationAction.activateLeft =>
        (index - 1 + _slotCount) % _slotCount,
      HomeSlotGridNavigationAction.activateRight => (index + 1) % _slotCount,
      HomeSlotGridNavigationAction.activateUp => layout == SlotLayout.twoByFour
          ? (index - columns + _slotCount) % _slotCount
          : (index - 1 + _slotCount) % _slotCount,
      HomeSlotGridNavigationAction.activateDown =>
        layout == SlotLayout.twoByFour
            ? (index + columns) % _slotCount
            : (index + 1) % _slotCount,
      HomeSlotGridNavigationAction.reorderLeft => visualLeft,
      HomeSlotGridNavigationAction.reorderRight => visualRight,
      HomeSlotGridNavigationAction.reorderUp => layout == SlotLayout.twoByFour
          ? (index >= columns ? index - columns : null)
          : before,
      HomeSlotGridNavigationAction.reorderDown => layout == SlotLayout.twoByFour
          ? (index < columns ? index + columns : null)
          : after,
      HomeSlotGridNavigationAction.moveBefore => before,
      HomeSlotGridNavigationAction.moveAfter => after,
    };
  }
}
