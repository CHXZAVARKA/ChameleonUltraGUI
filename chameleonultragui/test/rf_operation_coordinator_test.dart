import 'dart:async';

import 'package:chameleonultragui/helpers/rf_operation_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('background operations skip while an operation is active', () async {
    final coordinator = RfOperationCoordinator();
    final release = Completer<void>();
    var operationsStarted = 0;

    final first = coordinator.tryRunBackground(() async {
      operationsStarted++;
      await release.future;
      return 'first';
    });
    await Future<void>.delayed(Duration.zero);

    final skipped = await coordinator.tryRunBackground(() async {
      operationsStarted++;
      return 'overlap';
    });

    expect(skipped.acquired, isFalse);
    expect(operationsStarted, 1);

    release.complete();
    expect((await first).value, 'first');
  });

  test('foreground operations are FIFO and background cannot starve them',
      () async {
    final coordinator = RfOperationCoordinator();
    final releaseBackground = Completer<void>();
    final releaseFirstForeground = Completer<void>();
    final order = <String>[];

    final background = coordinator.tryRunBackground(() async {
      order.add('background');
      await releaseBackground.future;
    });
    await Future<void>.delayed(Duration.zero);

    final first = coordinator.runForeground(() async {
      order.add('foreground-1');
      await releaseFirstForeground.future;
    });
    final second = coordinator.runForeground(() async {
      order.add('foreground-2');
    });

    expect((await coordinator.tryRunBackground(() async {})).acquired, isFalse);

    releaseBackground.complete();
    await background;
    await Future<void>.delayed(Duration.zero);
    expect(order, ['background', 'foreground-1']);

    expect((await coordinator.tryRunBackground(() async {})).acquired, isFalse);

    releaseFirstForeground.complete();
    await first;
    await second;
    expect(order, ['background', 'foreground-1', 'foreground-2']);
  });

  test('throwing operations release their lease', () async {
    final coordinator = RfOperationCoordinator();

    await expectLater(
      coordinator.tryRunBackground<void>(() async => throw StateError('boom')),
      throwsStateError,
    );
    expect(await coordinator.runForeground(() async => 42), 42);

    await expectLater(
      coordinator.runForeground<void>(() async => throw StateError('boom')),
      throwsStateError,
    );
    expect(
      (await coordinator.tryRunBackground(() async => 'available')).value,
      'available',
    );
  });
}
