import 'package:chameleonultragui/gui/component/chameleon_loading_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
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

  testWidgets('overlays C and U on the same square canvas', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ChameleonLoadingIndicator()),
      ),
    );

    final cMark = tester.widget<SvgPicture>(
      find.byKey(const Key('chameleon-loader-c-svg')),
    );
    final uMark = tester.widget<SvgPicture>(
      find.byKey(const Key('chameleon-loader-u-svg')),
    );
    expect(cMark.width, 40.32);
    expect(cMark.height, 40.32);
    expect(uMark.width, cMark.width);
    expect(uMark.height, cMark.height);
  });

  testWidgets('cycles through colors from the active theme', (tester) async {
    const primary = Color(0xFF1357A6);
    const secondary = Color(0xFF27A36A);
    const tertiary = Color(0xFFB83D8B);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: primary,
          ).copyWith(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
          ),
        ),
        home: const Scaffold(body: ChameleonLoadingIndicator()),
      ),
    );

    final initialC = tester.widget<SvgPicture>(
      find.byKey(const Key('chameleon-loader-c-svg')),
    );
    final initialU = tester.widget<SvgPicture>(
      find.byKey(const Key('chameleon-loader-u-svg')),
    );
    expect(
      initialC.colorFilter,
      const ColorFilter.mode(primary, BlendMode.srcIn),
    );
    expect(
      initialU.colorFilter,
      const ColorFilter.mode(tertiary, BlendMode.srcIn),
    );

    await tester.pump(const Duration(milliseconds: 350));

    final animatedC = tester.widget<SvgPicture>(
      find.byKey(const Key('chameleon-loader-c-svg')),
    );
    final animatedU = tester.widget<SvgPicture>(
      find.byKey(const Key('chameleon-loader-u-svg')),
    );
    expect(animatedC.colorFilter, isNot(initialC.colorFilter));
    expect(animatedU.colorFilter, isNot(initialU.colorFilter));
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
    final beforeColor = tester
        .widget<SvgPicture>(find.byKey(const Key('chameleon-loader-c-svg')))
        .colorFilter;

    await tester.pump(const Duration(seconds: 2));

    final after = tester.widget<Transform>(
      find.byKey(const Key('chameleon-loader-c')),
    );
    expect(after.transform, beforeTransform);
    expect(
      tester
          .widget<SvgPicture>(find.byKey(const Key('chameleon-loader-c-svg')))
          .colorFilter,
      beforeColor,
    );
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
