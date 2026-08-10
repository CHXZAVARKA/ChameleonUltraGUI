import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Branded indeterminate progress indicator built from the Chameleon C/U mark.
class ChameleonLoadingIndicator extends StatefulWidget {
  const ChameleonLoadingIndicator({
    super.key,
    this.size = 56,
    this.color,
    this.accentColor,
    this.semanticLabel,
  });

  final double size;
  final Color? color;
  final Color? accentColor;
  final String? semanticLabel;

  @override
  State<ChameleonLoadingIndicator> createState() =>
      _ChameleonLoadingIndicatorState();
}

class _ChameleonLoadingIndicatorState extends State<ChameleonLoadingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller
        ..stop()
        ..value = 0;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Color _cycleColor(List<Color> colors, double progress) {
    if (colors.length == 1) return colors.single;
    final position = (progress % 1) * colors.length;
    final index = position.floor();
    return Color.lerp(
      colors[index],
      colors[(index + 1) % colors.length],
      position - index,
    )!;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final outerColor = widget.color ?? colorScheme.primary;
    final innerColor = widget.accentColor ?? colorScheme.tertiary;
    final palette = widget.color == null && widget.accentColor == null
        ? [colorScheme.primary, colorScheme.secondary, colorScheme.tertiary]
        : [outerColor, innerColor];
    final innerPhase = palette.length == 3 ? 2 / 3 : 0.5;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);

    return Semantics(
      label: widget.semanticLabel,
      child: SizedBox.square(
        dimension: widget.size,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final progress = reducedMotion ? 0.0 : _controller.value;
            final innerScale = reducedMotion
                ? 1.0
                : 0.9 + 0.1 * ((1 - math.cos(progress * math.pi * 2)) / 2);
            final animatedOuterColor = _cycleColor(palette, progress);
            final animatedInnerColor = _cycleColor(
              palette,
              (progress + innerPhase) % 1,
            );
            final markSize = widget.size * 0.72;
            return Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                Transform.rotate(
                  key: const Key('chameleon-loader-c'),
                  angle: progress * math.pi * 2,
                  child: SvgPicture.asset(
                    'assets/loading/chameleon-c.svg',
                    key: const Key('chameleon-loader-c-svg'),
                    width: markSize,
                    height: markSize,
                    colorFilter: ColorFilter.mode(
                      animatedOuterColor,
                      BlendMode.srcIn,
                    ),
                  ),
                ),
                Transform.scale(
                  key: const Key('chameleon-loader-u'),
                  scale: innerScale,
                  child: SvgPicture.asset(
                    'assets/loading/chameleon-u.svg',
                    key: const Key('chameleon-loader-u-svg'),
                    width: markSize,
                    height: markSize,
                    colorFilter: ColorFilter.mode(
                      animatedInnerColor,
                      BlendMode.srcIn,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
