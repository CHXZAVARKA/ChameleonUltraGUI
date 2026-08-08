import 'dart:async';

import 'package:chameleonultragui/helpers/rf_operation_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('background status read skips while RF work is active', () async {
    final coordinator = RfOperationCoordinator();
    final activeOperation = Completer<void>();

    final active = coordinator.tryRunBackground(() => activeOperation.future);
    await Future<void>.delayed(Duration.zero);

    final skipped = await coordinator.tryRunBackground(() async => 'battery');
    expect(skipped.acquired, isFalse);

    activeOperation.complete();
    await active;

    final available = await coordinator.tryRunBackground(() async => 'battery');
    expect(available.acquired, isTrue);
    expect(available.value, 'battery');
  });

  test('foreground RF work is FIFO and releases after errors', () async {
    final coordinator = RfOperationCoordinator();
    final firstGate = Completer<void>();
    final order = <String>[];

    final first = coordinator.runForeground(() async {
      order.add('first');
      await firstGate.future;
    });
    final second = coordinator.runForeground(() async {
      order.add('second');
      throw StateError('expected');
    });

    firstGate.complete();
    await first;
    await expectLater(second, throwsStateError);

    final background =
        await coordinator.tryRunBackground(() async => 'released');
    expect(order, ['first', 'second']);
    expect(background.value, 'released');
  });
}
