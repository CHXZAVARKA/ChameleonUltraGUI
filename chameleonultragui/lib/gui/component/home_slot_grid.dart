import 'dart:math' as math;

import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:chameleonultragui/status/connected_device_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class HomeSlotGrid extends StatefulWidget {
  const HomeSlotGrid({
    super.key,
    required this.status,
    this.layout = SlotLayout.eightAcross,
  });

  final ConnectedDeviceStatus status;
  final SlotLayout layout;

  @override
  State<HomeSlotGrid> createState() => _HomeSlotGridState();
}

class _HomeSlotGridState extends State<HomeSlotGrid> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'Home slot grid');
  final ScrollController _eightAcrossController = ScrollController(
    keepScrollOffset: false,
  );
  final List<GlobalKey> _slotKeys = List.generate(
    8,
    (index) => GlobalKey(debugLabel: 'Home slot ${index + 1}'),
  );
  var _focusedSlot = 0;
  var _hasFocus = false;
  var _eightAcrossOffset = 0.0;
  var _restoringEightAcrossOffset = false;

  @override
  void initState() {
    super.initState();
    _eightAcrossController.addListener(_rememberEightAcrossOffset);
  }

  void _rememberEightAcrossOffset() {
    if (!_restoringEightAcrossOffset && _eightAcrossController.hasClients) {
      _eightAcrossOffset = _eightAcrossController.offset;
    }
  }

  @override
  void didUpdateWidget(HomeSlotGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.layout == SlotLayout.eightAcross &&
        widget.layout != SlotLayout.eightAcross &&
        _eightAcrossController.hasClients) {
      _eightAcrossOffset = _eightAcrossController.offset;
    }
    if (oldWidget.layout != SlotLayout.eightAcross &&
        widget.layout == SlotLayout.eightAcross) {
      _restoringEightAcrossOffset = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        if (_eightAcrossController.hasClients) {
          final position = _eightAcrossController.position;
          _eightAcrossController.jumpTo(
            _eightAcrossOffset.clamp(
              position.minScrollExtent,
              position.maxScrollExtent,
            ),
          );
        }
        _restoringEightAcrossOffset = false;
      });
    }
  }

  @override
  void dispose() {
    _eightAcrossController
      ..removeListener(_rememberEightAcrossOffset)
      ..dispose();
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final numberedSlot = _numberedSlot(event.logicalKey);
    if (numberedSlot != null) {
      _activateFromKeyboard(numberedSlot);
      return KeyEventResult.handled;
    }
    final direction = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowLeft => -1,
      LogicalKeyboardKey.arrowRight => 1,
      LogicalKeyboardKey.arrowUp =>
        widget.layout == SlotLayout.twoByFour ? -4 : -1,
      LogicalKeyboardKey.arrowDown =>
        widget.layout == SlotLayout.twoByFour ? 4 : 1,
      _ => null,
    };
    if (direction != null) {
      _activateFromKeyboard((_focusedSlot + direction + 8) % 8);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.space) {
      _activate(_focusedSlot);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  int? _numberedSlot(LogicalKeyboardKey key) => switch (key) {
        LogicalKeyboardKey.digit1 || LogicalKeyboardKey.numpad1 => 0,
        LogicalKeyboardKey.digit2 || LogicalKeyboardKey.numpad2 => 1,
        LogicalKeyboardKey.digit3 || LogicalKeyboardKey.numpad3 => 2,
        LogicalKeyboardKey.digit4 || LogicalKeyboardKey.numpad4 => 3,
        LogicalKeyboardKey.digit5 || LogicalKeyboardKey.numpad5 => 4,
        LogicalKeyboardKey.digit6 || LogicalKeyboardKey.numpad6 => 5,
        LogicalKeyboardKey.digit7 || LogicalKeyboardKey.numpad7 => 6,
        LogicalKeyboardKey.digit8 || LogicalKeyboardKey.numpad8 => 7,
        _ => null,
      };

  void _activateFromKeyboard(int slot) {
    if (widget.status.snapshot.slots.pendingActivation != null) {
      return;
    }
    if (_focusedSlot != slot) {
      setState(() => _focusedSlot = slot);
    }
    _revealFocusedSlot();
    _activate(slot);
  }

  void _revealFocusedSlot() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final slotContext = _slotKeys[_focusedSlot].currentContext;
      if (slotContext != null) {
        Scrollable.ensureVisible(slotContext, alignment: 0.5);
      }
    });
  }

  Future<void> _activate(int index) async {
    final invokedStatus = widget.status;
    if (invokedStatus.snapshot.slots.pendingActivation != null) {
      return;
    }
    _focusNode.requestFocus();
    if (_focusedSlot != index) {
      setState(() => _focusedSlot = index);
    }
    final confirmed = await invokedStatus.activateSlot(index);
    if (!confirmed && mounted && identical(widget.status, invokedStatus)) {
      final localizations = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            key: const Key('home-slot-activation-error'),
            content: Text(
              '${localizations.error}: ${localizations.unavailable}',
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: widget.status,
      builder: (context, _) {
        final slots = widget.status.snapshot.slots;
        final activeSlot = slots.activeSlot.value;
        return ConstrainedBox(
          key: const Key('home-slot-grid'),
          constraints: const BoxConstraints(maxWidth: 680),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Flexible(
                child: Focus(
                  key: const Key('home-slot-grid-focus'),
                  focusNode: _focusNode,
                  autofocus: true,
                  onFocusChange: (value) {
                    if (_hasFocus != value) {
                      setState(() {
                        _hasFocus = value;
                        if (value && activeSlot != null) {
                          _focusedSlot = activeSlot;
                          _revealFocusedSlot();
                        }
                      });
                    }
                  },
                  onKeyEvent: _handleKey,
                  child: Semantics(
                    container: true,
                    label: localizations.slot_grid_description,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final textScaler = MediaQuery.textScalerOf(context);
                        final textDirection = Directionality.of(context);
                        final frequencyStyle = Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(fontWeight: FontWeight.w700);
                        Size measureText(String text, TextStyle? style) {
                          final painter = TextPainter(
                            text: TextSpan(text: text, style: style),
                            textDirection: textDirection,
                            textScaler: textScaler,
                          )..layout();
                          final size = painter.size;
                          painter.dispose();
                          return size;
                        }

                        final hfLabelSize =
                            measureText(localizations.hf, frequencyStyle);
                        final lfLabelSize =
                            measureText(localizations.lf, frequencyStyle);
                        final labelWidth = math.max(
                          28.0,
                          math.max(hfLabelSize.width, lfLabelSize.width) + 4,
                        );
                        final availableSlotsWidth = math.max(
                          0.0,
                          constraints.maxWidth - labelWidth,
                        );
                        final columns =
                            widget.layout == SlotLayout.twoByFour ? 4 : 8;
                        final slotWidth = math.max(
                          48.0,
                          availableSlotsWidth / columns,
                        );
                        final markSize = (slotWidth * 0.56).clamp(18.0, 30.0);
                        final markRowHeight = math.max(
                          markSize,
                          math.max(hfLabelSize.height, lfLabelSize.height),
                        );
                        final slotNumberPainter = TextPainter(
                          text: TextSpan(
                            text: '8',
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                          textDirection: textDirection,
                          textScaler: textScaler,
                        )..layout();
                        final slotNumberHeight = slotNumberPainter.height;
                        slotNumberPainter.dispose();
                        final gridHeight =
                            markRowHeight * 2 + 29 + slotNumberHeight;
                        Widget buildSlot(int index) => SizedBox(
                              key: _slotKeys[index],
                              width: slotWidth,
                              height: gridHeight,
                              child: _SlotColumn(
                                index: index,
                                slot: slots.slots[index],
                                markSize: markSize,
                                markRowHeight: markRowHeight,
                                loading: slots.availability ==
                                    SlotsAvailability.loading,
                                active: activeSlot == index &&
                                    slots.activeSlot.isConfirmed,
                                activating: slots.pendingActivation == index,
                                focused: _hasFocus && _focusedSlot == index,
                                blocked: slots.pendingActivation != null,
                                onTap: () => _activate(index),
                              ),
                            );
                        Widget buildRow(int firstSlot) => SizedBox(
                              width: labelWidth + slotWidth * columns,
                              height: gridHeight,
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _FrequencyLabels(
                                    rowHeight: markRowHeight,
                                    width: labelWidth,
                                    rowStart: firstSlot,
                                  ),
                                  for (var offset = 0;
                                      offset < columns;
                                      offset++)
                                    buildSlot(firstSlot + offset),
                                ],
                              ),
                            );

                        if (widget.layout == SlotLayout.twoByFour) {
                          return SizedBox(
                            key: const Key('home-slot-grid-two-by-four'),
                            width: labelWidth + slotWidth * columns,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                buildRow(0),
                                const SizedBox(height: 12),
                                buildRow(4),
                              ],
                            ),
                          );
                        }

                        return Row(
                          key: const Key('home-slot-grid-eight-across'),
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _FrequencyLabels(
                              rowHeight: markRowHeight,
                              width: labelWidth,
                              rowStart: 0,
                            ),
                            SizedBox(
                              key: const Key('home-slot-grid-scroll'),
                              width: availableSlotsWidth,
                              height: gridHeight,
                              child: SingleChildScrollView(
                                controller: _eightAcrossController,
                                scrollDirection: Axis.horizontal,
                                child: SizedBox(
                                  width: slotWidth * columns,
                                  height: gridHeight,
                                  child: Row(
                                    children: [
                                      for (var index = 0;
                                          index < columns;
                                          index++)
                                        buildSlot(index),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _FrequencyLabels extends StatelessWidget {
  const _FrequencyLabels({
    required this.rowHeight,
    required this.width,
    required this.rowStart,
  });

  final double rowHeight;
  final double width;
  final int rowStart;

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
        );
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Column(
          children: [
            SizedBox(
              key: Key('home-frequency-label-hf-box-$rowStart'),
              height: rowHeight,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(localizations.hf, style: style),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              key: Key('home-frequency-label-lf-box-$rowStart'),
              height: rowHeight,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(localizations.lf, style: style),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _SlotMarkState {
  enabled,
  disabled,
  empty,
  enabledUnknown,
  unavailable,
  loading
}

class _SlotColumn extends StatelessWidget {
  const _SlotColumn({
    required this.index,
    required this.slot,
    required this.markSize,
    required this.markRowHeight,
    required this.loading,
    required this.active,
    required this.activating,
    required this.focused,
    required this.blocked,
    required this.onTap,
  });

  final int index;
  final DeviceSlotStatus slot;
  final double markSize;
  final double markRowHeight;
  final bool loading;
  final bool active;
  final bool activating;
  final bool focused;
  final bool blocked;
  final VoidCallback onTap;

  String _frequencyDescription(
    AppLocalizations localizations,
    String frequency,
    SlotFrequencyStatus status,
  ) {
    final state = _markState(status);
    final stateLabel = switch (state) {
      _SlotMarkState.enabled => localizations.enabled,
      _SlotMarkState.disabled => localizations.disabled,
      _SlotMarkState.empty => localizations.empty,
      _SlotMarkState.enabledUnknown =>
        '${localizations.enabled_status_unknown}, ${localizations.dashed_outline}',
      _SlotMarkState.unavailable => localizations.unavailable,
      _SlotMarkState.loading => localizations.loading,
    };
    final name = status.name.isConfirmed
        ? status.name.value!.isEmpty
            ? localizations.no_name
            : status.name.value!
        : localizations.unavailable;
    final type = status.type.isConfirmed
        ? status.type.value == null || status.type.value == TagType.unknown
            ? localizations.empty
            : chameleonTagToString(status.type.value!, localizations)
        : localizations.unavailable;
    return '$frequency: $name · $type · $stateLabel';
  }

  _SlotMarkState _markState(SlotFrequencyStatus status) {
    if (loading) {
      return _SlotMarkState.loading;
    }
    if (!status.type.isConfirmed) {
      return _SlotMarkState.unavailable;
    }
    if (status.type.value == null || status.type.value == TagType.unknown) {
      return _SlotMarkState.empty;
    }
    if (!status.enabled.isConfirmed) {
      return _SlotMarkState.enabledUnknown;
    }
    return status.enabled.value == true
        ? _SlotMarkState.enabled
        : _SlotMarkState.disabled;
  }

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    const activeFrameColor = Colors.white;
    final tooltip = '${localizations.slot} ${index + 1}\n'
        '${_frequencyDescription(localizations, localizations.hf, slot.hf)}\n'
        '${_frequencyDescription(localizations, localizations.lf, slot.lf)}'
        '${active ? '\n${localizations.active_slot}' : ''}'
        '${activating ? '\n${localizations.activating}' : ''}';
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: !blocked,
        selected: active,
        label: tooltip.replaceAll('\n', '. '),
        excludeSemantics: true,
        onTap: blocked ? null : onTap,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: Key('home-slot-${index + 1}'),
            excludeFromSemantics: true,
            borderRadius: BorderRadius.circular(18),
            onTap: blocked ? null : onTap,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                AnimatedContainer(
                  key: active ? Key('home-active-slot-${index + 1}') : null,
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  padding: const EdgeInsets.fromLTRB(3, 6, 3, 5),
                  decoration: BoxDecoration(
                    color: focused
                        ? theme.colorScheme.primary.withValues(alpha: 0.08)
                        : null,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: active
                          ? activeFrameColor
                          : focused
                              ? theme.colorScheme.outline
                              : Colors.transparent,
                      width: active ? 2 : 1,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (activating)
                        SizedBox(
                          key: Key('home-slot-${index + 1}-progress'),
                          height: markRowHeight * 2 + 8,
                          child: Center(
                            child: SizedBox.square(
                              dimension: math.max(24, markSize),
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ),
                        )
                      else ...[
                        SizedBox(
                          height: markRowHeight,
                          child: Center(
                            child: _SlotStatusMark(
                              key: Key(
                                'home-slot-${index + 1}-hf-mark-${_markState(slot.hf).name}',
                              ),
                              frequency: TagFrequency.hf,
                              state: _markState(slot.hf),
                              size: markSize,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          height: markRowHeight,
                          child: Center(
                            child: _SlotStatusMark(
                              key: Key(
                                'home-slot-${index + 1}-lf-mark-${_markState(slot.lf).name}',
                              ),
                              frequency: TagFrequency.lf,
                              state: _markState(slot.lf),
                              size: markSize,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 4),
                      Text(
                        '${index + 1}',
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: active ? FontWeight.w700 : null,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SlotStatusMark extends StatelessWidget {
  const _SlotStatusMark({
    super.key,
    required this.frequency,
    required this.state,
    required this.size,
  });

  final TagFrequency frequency;
  final _SlotMarkState state;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final frequencyColor = frequency == TagFrequency.hf
        ? (dark ? Colors.green.shade300 : Colors.green.shade700)
        : (dark ? Colors.blue.shade300 : Colors.blue.shade700);
    final neutral = theme.colorScheme.outlineVariant;
    return SizedBox.square(
      dimension: size,
      child: switch (state) {
        _SlotMarkState.enabled => DecoratedBox(
            decoration: BoxDecoration(
              color: frequencyColor,
              shape: BoxShape.circle,
            ),
          ),
        _SlotMarkState.disabled => DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: frequencyColor, width: 2),
            ),
          ),
        _SlotMarkState.empty => DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: neutral, width: 2),
            ),
          ),
        _SlotMarkState.enabledUnknown => CustomPaint(
            painter: _DashedCirclePainter(color: frequencyColor),
          ),
        _SlotMarkState.unavailable => CustomPaint(
            painter: _DashedCirclePainter(color: neutral),
          ),
        _SlotMarkState.loading => _SoftPulseCircle(
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.24),
          ),
      },
    );
  }
}

class _DashedCirclePainter extends CustomPainter {
  const _DashedCirclePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final rect = Offset.zero & size;
    const segmentCount = 10;
    const segmentSweep = math.pi * 2 / segmentCount * 0.58;
    for (var index = 0; index < segmentCount; index++) {
      final start = -math.pi / 2 + math.pi * 2 / segmentCount * index;
      canvas.drawArc(rect.deflate(1), start, segmentSweep, false, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _DashedCirclePainter oldDelegate) =>
      oldDelegate.color != color;
}

class _SoftPulseCircle extends StatefulWidget {
  const _SoftPulseCircle({required this.color});

  final Color color;

  @override
  State<_SoftPulseCircle> createState() => _SoftPulseCircleState();
}

class _SoftPulseCircleState extends State<_SoftPulseCircle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
    lowerBound: 0.58,
    upperBound: 1,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller
        ..stop()
        ..value = 0.72;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: widget.color,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
