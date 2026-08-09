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

  test('one status group can overlap without bypassing queued foreground work',
      () async {
    final coordinator = RfOperationCoordinator();
    final group = Object();
    final slotGate = Completer<void>();
    final order = <String>[];

    final slots = coordinator.tryRunBackground(() async {
      order.add('slots');
      await slotGate.future;
    }, group: group);
    final battery = await coordinator.tryRunBackground(() async {
      order.add('battery');
      return 61;
    }, group: group);
    expect(battery.value, 61);

    final foreground = coordinator.runForeground(() async {
      order.add('foreground');
    });
    final laterPoll = await coordinator.tryRunBackground(
      () async => 60,
      group: group,
    );
    expect(laterPoll.acquired, isFalse);

    slotGate.complete();
    await slots;
    await foreground;
    expect(order, ['slots', 'battery', 'foreground']);
  });

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
