import 'package:chameleonultragui/gui/component/chameleon_loading_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders both supplied C and U marks', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChameleonLoadingIndicator(semanticLabel: 'Loading'),
        ),
      ),
    );

    expect(find.byKey(const Key('chameleon-loader-c')), findsOneWidget);
    expect(find.byKey(const Key('chameleon-loader-u')), findsOneWidget);
    expect(find.bySemanticsLabel('Loading'), findsOneWidget);
  });

  testWidgets('animates the outer C mark', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ChameleonLoadingIndicator()),
      ),
    );

    final before = tester.widget<Transform>(
      find.byKey(const Key('chameleon-loader-c')),
    );
    final beforeTransform = before.transform.clone();

    await tester.pump(const Duration(milliseconds: 350));

    final after = tester.widget<Transform>(
      find.byKey(const Key('chameleon-loader-c')),
    );
    expect(after.transform, isNot(beforeTransform));
  });

  testWidgets('optically aligns C above the geometric U center',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ChameleonLoadingIndicator()),
      ),
    );

    final alignment = tester.widget<Transform>(
      find.byKey(const Key('chameleon-loader-c-alignment')),
    );
    expect(alignment.transform.storage[13], closeTo(-1, 0.01));
  });

  testWidgets('stays still when reduced motion is enabled', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Scaffold(body: ChameleonLoadingIndicator()),
        ),
      ),
    );

    final before = tester.widget<Transform>(
      find.byKey(const Key('chameleon-loader-c')),
    );
    final beforeTransform = before.transform.clone();

    await tester.pump(const Duration(seconds: 2));

    final after = tester.widget<Transform>(
      find.byKey(const Key('chameleon-loader-c')),
    );
    expect(after.transform, beforeTransform);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
