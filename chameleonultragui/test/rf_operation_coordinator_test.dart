import 'dart:async';

import 'package:chameleonultragui/helpers/rf_operation_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('background operations skip while an operation is active', () async {
    final coordinator = RfOperationCoordinator();
    final firstOperation = Completer<void>();
    var operationsStarted = 0;

    final first = coordinator.tryRunBackground(() async {
      operationsStarted++;
      await firstOperation.future;
      return 'first';
    });
    await Future<void>.delayed(Duration.zero);

    final skipped = await coordinator.tryRunBackground(() async {
      operationsStarted++;
      return 'overlap';
    });

    expect(skipped.acquired, isFalse);
    expect(operationsStarted, 1);

    firstOperation.complete();
    expect((await first).value, 'first');

    final resumed = await coordinator.tryRunBackground(() async {
      operationsStarted++;
      return 'resumed';
    });
    expect(resumed.acquired, isTrue);
    expect(resumed.value, 'resumed');
    expect(operationsStarted, 2);
  });

  test('foreground operations are FIFO and are not starved by background',
      () async {
    final coordinator = RfOperationCoordinator();
    final backgroundOperation = Completer<void>();
    final firstForeground = Completer<void>();
    final order = <String>[];

    final background = coordinator.tryRunBackground(() async {
      order.add('background');
      await backgroundOperation.future;
    });
    await Future<void>.delayed(Duration.zero);

    final first = coordinator.runForeground(() async {
      order.add('foreground-1');
      await firstForeground.future;
    });
    final second = coordinator.runForeground(() async {
      order.add('foreground-2');
    });

    final skipped = await coordinator.tryRunBackground(() async {
      order.add('background-overlap');
    });
    expect(skipped.acquired, isFalse);

    backgroundOperation.complete();
    await background;
    await Future<void>.delayed(Duration.zero);
    expect(order, ['background', 'foreground-1']);

    final skippedForWaiter = await coordinator.tryRunBackground(() async {
      order.add('background-between-waiters');
    });
    expect(skippedForWaiter.acquired, isFalse);

    firstForeground.complete();
    await first;
    await second;
    expect(order, ['background', 'foreground-1', 'foreground-2']);
  });

  test('throwing operations always release their lease', () async {
    final coordinator = RfOperationCoordinator();

    await expectLater(
      coordinator.tryRunBackground<void>(() async => throw StateError('boom')),
      throwsStateError,
    );

    final foreground = await coordinator.runForeground(() async => 42);
    expect(foreground, 42);

    await expectLater(
      coordinator.runForeground<void>(() async => throw StateError('boom')),
      throwsStateError,
    );

    final background =
        await coordinator.tryRunBackground(() async => 'available');
    expect(background.acquired, isTrue);
    expect(background.value, 'available');
  });
}
