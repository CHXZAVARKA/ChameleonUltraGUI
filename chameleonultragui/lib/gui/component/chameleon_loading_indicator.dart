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
  static const _cVerticalOffsetFactor = -0.04;

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

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final outerColor = widget.color ?? colorScheme.primary;
    final innerColor = widget.accentColor ?? colorScheme.tertiary;
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
            return Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                Transform.translate(
                  key: const Key('chameleon-loader-c-alignment'),
                  offset: Offset(0, widget.size * _cVerticalOffsetFactor),
                  child: Transform.rotate(
                    key: const Key('chameleon-loader-c'),
                    angle: progress * math.pi * 2,
                    child: SvgPicture.asset(
                      'assets/loading/chameleon-c.svg',
                      width: widget.size * 0.62,
                      height: widget.size * 0.72,
                      colorFilter: ColorFilter.mode(
                        outerColor,
                        BlendMode.srcIn,
                      ),
                    ),
                  ),
                ),
                Transform.scale(
                  key: const Key('chameleon-loader-u'),
                  scale: innerScale,
                  child: SvgPicture.asset(
                    'assets/loading/chameleon-u.svg',
                    width: widget.size * 0.38,
                    height: widget.size * 0.33,
                    colorFilter: ColorFilter.mode(
                      innerColor,
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
