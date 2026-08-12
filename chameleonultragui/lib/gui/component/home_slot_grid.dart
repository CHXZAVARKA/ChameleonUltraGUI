import 'dart:async';
import 'dart:math' as math;

import 'package:chameleonultragui/gui/component/chameleon_loading_indicator.dart';
import 'package:chameleonultragui/gui/component/home_slot_grid_navigation.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:chameleonultragui/status/connected_device_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
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
  final GlobalKey _eightAcrossViewportKey = GlobalKey(
    debugLabel: 'Home slot grid scroll viewport',
  );
  var _focusedSlot = 0;
  int? _lastConfirmedActiveSlot;
  int? _dragSource;
  int? _dragTarget;
  var _hasFocus = false;
  var _eightAcrossOffset = 0.0;
  var _restoringEightAcrossOffset = false;
  Timer? _autoScrollTimer;
  double _autoScrollDirection = 0;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _reorderFeedback;

  @override
  void initState() {
    super.initState();
    _eightAcrossController.addListener(_rememberEightAcrossOffset);
    unawaited(widget.status.refreshSlotReorderCapability());
  }

  void _rememberEightAcrossOffset() {
    if (!_restoringEightAcrossOffset && _eightAcrossController.hasClients) {
      _eightAcrossOffset = _eightAcrossController.offset;
    }
  }

  @override
  void didUpdateWidget(HomeSlotGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.status, widget.status)) {
      _dismissReorderFeedback();
      _lastConfirmedActiveSlot = null;
      _stopAutoScroll();
      _dragSource = null;
      _dragTarget = null;
      unawaited(widget.status.refreshSlotReorderCapability());
    }
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
    _stopAutoScroll();
    _reorderFeedback?.close();
    _reorderFeedback = null;
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
    final reordering = HardwareKeyboard.instance.isShiftPressed;
    final navigationAction = _navigationActionFor(
      event.logicalKey,
      reordering: reordering,
    );
    if (navigationAction != null) {
      final target = HomeSlotGridNavigation.target(
        index: _focusedSlot,
        layout: widget.layout,
        textDirection: Directionality.of(context),
        action: navigationAction,
      );
      if (reordering) {
        if (target != null && _canStartReorder) {
          unawaited(_reorder(_focusedSlot, target));
        }
        return KeyEventResult.handled;
      }
      _activateFromKeyboard(target!);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.space) {
      _activate(_focusedSlot);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  HomeSlotGridNavigationAction? _navigationActionFor(
    LogicalKeyboardKey key, {
    required bool reordering,
  }) =>
      switch ((key, reordering)) {
        (LogicalKeyboardKey.arrowLeft, false) =>
          HomeSlotGridNavigationAction.activateLeft,
        (LogicalKeyboardKey.arrowRight, false) =>
          HomeSlotGridNavigationAction.activateRight,
        (LogicalKeyboardKey.arrowUp, false) =>
          HomeSlotGridNavigationAction.activateUp,
        (LogicalKeyboardKey.arrowDown, false) =>
          HomeSlotGridNavigationAction.activateDown,
        (LogicalKeyboardKey.arrowLeft, true) =>
          HomeSlotGridNavigationAction.reorderLeft,
        (LogicalKeyboardKey.arrowRight, true) =>
          HomeSlotGridNavigationAction.reorderRight,
        (LogicalKeyboardKey.arrowUp, true) =>
          HomeSlotGridNavigationAction.reorderUp,
        (LogicalKeyboardKey.arrowDown, true) =>
          HomeSlotGridNavigationAction.reorderDown,
        _ => null,
      };

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
    if (_activationBlocked) {
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
    final slots = invokedStatus.snapshot.slots;
    if (slots.pendingActivation != null || slots.pendingReorder != null) {
      return;
    }
    _focusNode.requestFocus();
    if (_focusedSlot != index) {
      setState(() => _focusedSlot = index);
    }
    final confirmed = await invokedStatus.activateSlot(index);
    if (!confirmed &&
        mounted &&
        invokedStatus.isCurrentSession &&
        identical(widget.status, invokedStatus)) {
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

  bool get _activationBlocked {
    final slots = widget.status.snapshot.slots;
    return slots.pendingActivation != null || slots.pendingReorder != null;
  }

  bool get _canStartReorder {
    return _canStartReorderFor(widget.status);
  }

  Future<void> _reorder(
    int source,
    int target, {
    ConnectedDeviceStatus? originatingStatus,
  }) async {
    final invokedStatus = originatingStatus ?? widget.status;
    if (!identical(widget.status, invokedStatus) ||
        !invokedStatus.isCurrentSession ||
        source == target ||
        !_canStartReorderFor(invokedStatus)) {
      return;
    }
    final outcome = await invokedStatus.reorderSlots(source, target);
    if (!mounted ||
        !invokedStatus.isCurrentSession ||
        !identical(widget.status, invokedStatus)) {
      return;
    }
    if (outcome == SlotReorderOutcome.confirmed) {
      if (_focusedSlot == source) {
        setState(() => _focusedSlot = target);
        _revealFocusedSlot();
      }
      return;
    }
    if (outcome == SlotReorderOutcome.busy ||
        outcome == SlotReorderOutcome.connectionChanged ||
        outcome == SlotReorderOutcome.invalid) {
      return;
    }
    final localizations = AppLocalizations.of(context)!;
    final detail = switch (outcome) {
      SlotReorderOutcome.unsupported =>
        localizations.slot_reorder_unsupported_firmware,
      SlotReorderOutcome.ambiguous => localizations.slot_reorder_ambiguous,
      SlotReorderOutcome.reconciliationFailed =>
        localizations.slot_reorder_reconciliation_failed,
      _ => localizations.slot_reorder_failed,
    };
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    final feedback = messenger.showSnackBar(
      SnackBar(
        key: const Key('home-slot-reorder-error'),
        content: Text('${localizations.error}: $detail'),
        action: SnackBarAction(
          label: localizations.retry,
          onPressed: () => unawaited(
            _reorder(source, target, originatingStatus: invokedStatus),
          ),
        ),
      ),
    );
    _reorderFeedback = feedback;
    unawaited(
      feedback.closed.then((_) {
        if (identical(_reorderFeedback, feedback)) {
          _reorderFeedback = null;
        }
      }),
    );
  }

  bool _canStartReorderFor(ConnectedDeviceStatus status) {
    final slots = status.snapshot.slots;
    return slots.reorderCapability == SlotReorderCapability.supported &&
        slots.pendingActivation == null &&
        slots.pendingReorder == null;
  }

  void _dismissReorderFeedback() {
    _reorderFeedback?.close();
    _reorderFeedback = null;
  }

  void _startDrag(int source) {
    if (!_canStartReorder) {
      return;
    }
    _focusNode.requestFocus();
    setState(() {
      _focusedSlot = source;
      _dragSource = source;
      _dragTarget = null;
    });
  }

  void _hoverDragTarget(int source, int target) {
    if (_dragSource != source || source == target || !_canStartReorder) {
      return;
    }
    if (_dragTarget != target) {
      setState(() => _dragTarget = target);
    }
  }

  void _leaveDragTarget(int target) {
    if (_dragTarget == target && mounted) {
      setState(() => _dragTarget = null);
    }
  }

  void _acceptDrag(int source, int target) {
    if (_dragSource != source || source == target || !_canStartReorder) {
      _cancelDrag();
      return;
    }
    _stopAutoScroll();
    setState(() {
      _dragSource = null;
      _dragTarget = null;
    });
    unawaited(_reorder(source, target));
  }

  void _cancelDrag() {
    _stopAutoScroll();
    if (mounted && (_dragSource != null || _dragTarget != null)) {
      setState(() {
        _dragSource = null;
        _dragTarget = null;
      });
    } else {
      _dragSource = null;
      _dragTarget = null;
    }
  }

  void _updateAutoScroll(Offset globalPosition) {
    if (widget.layout != SlotLayout.eightAcross ||
        !_eightAcrossController.hasClients) {
      _stopAutoScroll();
      return;
    }
    final viewportContext = _eightAcrossViewportKey.currentContext;
    final renderObject = viewportContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      _stopAutoScroll();
      return;
    }
    final rect = renderObject.localToGlobal(Offset.zero) & renderObject.size;
    const edge = 52.0;
    final direction = globalPosition.dx < rect.left + edge
        ? -1.0
        : globalPosition.dx > rect.right - edge
            ? 1.0
            : 0.0;
    if (direction == _autoScrollDirection) {
      return;
    }
    _autoScrollDirection = direction;
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    if (direction == 0) {
      return;
    }
    _autoScrollTimer = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _scrollEightAcross(direction * 5),
    );
  }

  void _scrollEightAcross(double delta) {
    if (!mounted || !_eightAcrossController.hasClients) {
      _stopAutoScroll();
      return;
    }
    final position = _eightAcrossController.position;
    final directedDelta =
        position.axisDirection == AxisDirection.left ? -delta : delta;
    final target = (_eightAcrossController.offset + directedDelta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (target == _eightAcrossController.offset) {
      return;
    }
    _eightAcrossController.jumpTo(target);
  }

  void _stopAutoScroll() {
    _autoScrollDirection = 0;
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
  }

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: widget.status,
      builder: (context, _) {
        final slots = widget.status.snapshot.slots;
        final activeSlot = slots.activeSlot.value;
        final pendingReorder = slots.pendingReorder;
        if (slots.activeSlot.isConfirmed &&
            slots.pendingActivation == null &&
            activeSlot != null &&
            activeSlot != _lastConfirmedActiveSlot) {
          _lastConfirmedActiveSlot = activeSlot;
          _focusedSlot = activeSlot;
        }
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

                        final hfLabelSize = measureText(
                          localizations.hf,
                          frequencyStyle,
                        );
                        final lfLabelSize = measureText(
                          localizations.lf,
                          frequencyStyle,
                        );
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
                        final reducedMotion = MediaQuery.disableAnimationsOf(
                          context,
                        );
                        Widget slotColumn(int index, {bool preview = false}) {
                          final beforeTarget = HomeSlotGridNavigation.target(
                            index: index,
                            layout: widget.layout,
                            textDirection: textDirection,
                            action: HomeSlotGridNavigationAction.moveBefore,
                          );
                          final afterTarget = HomeSlotGridNavigation.target(
                            index: index,
                            layout: widget.layout,
                            textDirection: textDirection,
                            action: HomeSlotGridNavigationAction.moveAfter,
                          );
                          final actions = _canStartReorder
                              ? _SlotReorderActions(
                                  before: beforeTarget == null
                                      ? null
                                      : _SlotReorderAction(
                                          target: beforeTarget,
                                          invoke: () => unawaited(
                                            _reorder(index, beforeTarget),
                                          ),
                                        ),
                                  after: afterTarget == null
                                      ? null
                                      : _SlotReorderAction(
                                          target: afterTarget,
                                          invoke: () => unawaited(
                                            _reorder(index, afterTarget),
                                          ),
                                        ),
                                )
                              : const _SlotReorderActions.disabled();
                          final _SlotReorderPresentation reorder;
                          if (pendingReorder?.source == index) {
                            reorder = _SlotReorderPresentation.source(
                              capability: slots.reorderCapability,
                              enabled: false,
                              pending: true,
                              partner: pendingReorder!.target,
                              actions: actions,
                            );
                          } else if (pendingReorder?.target == index) {
                            reorder = _SlotReorderPresentation.destination(
                              capability: slots.reorderCapability,
                              enabled: false,
                              pending: true,
                              partner: pendingReorder!.source,
                              actions: actions,
                            );
                          } else if (_dragSource == index) {
                            reorder = _SlotReorderPresentation.source(
                              capability: slots.reorderCapability,
                              enabled: _canStartReorder,
                              pending: false,
                              partner: _dragTarget,
                              actions: actions,
                            );
                          } else if (_dragTarget == index) {
                            reorder = _SlotReorderPresentation.destination(
                              capability: slots.reorderCapability,
                              enabled: _canStartReorder,
                              pending: false,
                              partner: _dragSource!,
                              actions: actions,
                            );
                          } else {
                            reorder = _SlotReorderPresentation.idle(
                              capability: slots.reorderCapability,
                              enabled: _canStartReorder,
                              actions: actions,
                            );
                          }
                          return _SlotColumn(
                            index: index,
                            slot: slots.slots[index],
                            markSize: markSize,
                            markRowHeight: markRowHeight,
                            loading:
                                slots.availability == SlotsAvailability.loading,
                            active: activeSlot == index &&
                                slots.activeSlot.isConfirmed,
                            activating: slots.pendingActivation == index,
                            focused:
                                !preview && _hasFocus && _focusedSlot == index,
                            blocked: _activationBlocked,
                            reorder: reorder,
                            preview: preview,
                            onTap: () => _activate(index),
                          );
                        }

                        Widget buildSlot(int index) {
                          Widget child = slotColumn(index);
                          if (_canStartReorder) {
                            child = LongPressDraggable<int>(
                              key: Key('home-slot-${index + 1}-draggable'),
                              data: index,
                              maxSimultaneousDrags: 1,
                              hapticFeedbackOnStart: !reducedMotion,
                              onDragStarted: () => _startDrag(index),
                              onDragUpdate: (details) =>
                                  _updateAutoScroll(details.globalPosition),
                              onDragEnd: (_) => _cancelDrag(),
                              onDraggableCanceled: (_, __) => _cancelDrag(),
                              feedback: Material(
                                color: Colors.transparent,
                                child: Transform.scale(
                                  scale: reducedMotion ? 1 : 1.04,
                                  child: SizedBox(
                                    key: Key(
                                      'home-slot-${index + 1}-drag-preview',
                                    ),
                                    width: slotWidth,
                                    height: gridHeight,
                                    child: IgnorePointer(
                                      child: slotColumn(index, preview: true),
                                    ),
                                  ),
                                ),
                              ),
                              childWhenDragging: Opacity(
                                opacity: reducedMotion ? 1 : 0.72,
                                child: slotColumn(index),
                              ),
                              child: child,
                            );
                          }
                          return SizedBox(
                            key: _slotKeys[index],
                            width: slotWidth,
                            height: gridHeight,
                            child: DragTarget<int>(
                              key: Key('home-slot-${index + 1}-reorder-target'),
                              onWillAcceptWithDetails: (details) =>
                                  _canStartReorder && details.data != index,
                              onMove: (details) =>
                                  _hoverDragTarget(details.data, index),
                              onLeave: (_) => _leaveDragTarget(index),
                              onAcceptWithDetails: (details) =>
                                  _acceptDrag(details.data, index),
                              builder: (context, _, __) => child,
                            ),
                          );
                        }

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
                                key: _eightAcrossViewportKey,
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
  loading,
}

class _SlotReorderAction {
  const _SlotReorderAction({required this.target, required this.invoke});

  final int target;
  final VoidCallback invoke;
}

class _SlotReorderActions {
  const _SlotReorderActions({required this.before, required this.after});

  const _SlotReorderActions.disabled()
      : before = null,
        after = null;

  final _SlotReorderAction? before;
  final _SlotReorderAction? after;
}

enum _SlotReorderRole { idle, source, destination }

class _SlotReorderPresentation {
  const _SlotReorderPresentation.idle({
    required this.capability,
    required this.enabled,
    required this.actions,
  })  : role = _SlotReorderRole.idle,
        pending = false,
        partner = null;

  const _SlotReorderPresentation.source({
    required this.capability,
    required this.enabled,
    required this.pending,
    required this.partner,
    required this.actions,
  })  : assert(!pending || partner != null),
        assert(!pending || !enabled),
        role = _SlotReorderRole.source;

  const _SlotReorderPresentation.destination({
    required this.capability,
    required this.enabled,
    required this.pending,
    required int this.partner,
    required this.actions,
  })  : assert(!pending || !enabled),
        role = _SlotReorderRole.destination;

  final SlotReorderCapability capability;
  final bool enabled;
  final _SlotReorderRole role;
  final bool pending;
  final int? partner;
  final _SlotReorderActions actions;

  bool get isSource => role == _SlotReorderRole.source;
  bool get isDestination => role == _SlotReorderRole.destination;
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
    required this.reorder,
    required this.preview,
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
  final _SlotReorderPresentation reorder;
  final bool preview;
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
    final reorderDescription = switch (reorder.role) {
      _SlotReorderRole.idle => '',
      _SlotReorderRole.source when reorder.pending =>
        '\n${localizations.slot_reorder_pending_source(reorder.partner! + 1)}',
      _SlotReorderRole.source when reorder.partner != null =>
        '\n${localizations.slot_reorder_source_with_destination(reorder.partner! + 1)}',
      _SlotReorderRole.source => '\n${localizations.slot_reorder_source}',
      _SlotReorderRole.destination when reorder.pending =>
        '\n${localizations.slot_reorder_pending_destination(reorder.partner! + 1)}',
      _SlotReorderRole.destination =>
        '\n${localizations.slot_reorder_destination(reorder.partner! + 1)}',
    };
    final capabilityReason = switch (reorder.capability) {
      SlotReorderCapability.unsupported =>
        localizations.slot_reorder_unsupported_firmware,
      SlotReorderCapability.unavailable =>
        localizations.slot_reorder_check_unavailable,
      SlotReorderCapability.unknown => localizations.slot_reorder_checking,
      SlotReorderCapability.supported => '',
    };
    final capabilityDescription =
        capabilityReason.isEmpty ? '' : '\n$capabilityReason';
    final tooltip = '${localizations.slot} ${index + 1}\n'
        '${_frequencyDescription(localizations, localizations.hf, slot.hf)}\n'
        '${_frequencyDescription(localizations, localizations.lf, slot.lf)}'
        '${active ? '\n${localizations.active_slot}' : ''}'
        '${activating ? '\n${localizations.activating}' : ''}'
        '$reorderDescription$capabilityDescription';
    final customActions = <CustomSemanticsAction, VoidCallback>{
      if (reorder.actions.before case final action?)
        CustomSemanticsAction(
          label: localizations.slot_reorder_move_before(action.target + 1),
        ): action.invoke,
      if (reorder.actions.after case final action?)
        CustomSemanticsAction(
          label: localizations.slot_reorder_move_after(action.target + 1),
        ): action.invoke,
    };
    return Tooltip(
      message: tooltip,
      triggerMode: reorder.enabled
          ? TooltipTriggerMode.manual
          : TooltipTriggerMode.longPress,
      child: Semantics(
        button: true,
        enabled: !blocked,
        selected: active,
        label: tooltip.replaceAll('\n', '. '),
        hint: capabilityReason.isEmpty ? null : capabilityReason,
        excludeSemantics: true,
        onTap: blocked ? null : onTap,
        customSemanticsActions: customActions,
        child: MouseRegion(
          cursor: blocked
              ? SystemMouseCursors.basic
              : reorder.enabled
                  ? SystemMouseCursors.grab
                  : SystemMouseCursors.click,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              key: Key(
                preview
                    ? 'home-slot-${index + 1}-preview-content'
                    : 'home-slot-${index + 1}',
              ),
              excludeFromSemantics: true,
              borderRadius: BorderRadius.circular(18),
              onTap: blocked || preview ? null : onTap,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  AnimatedContainer(
                    key: active && !preview
                        ? Key('home-active-slot-${index + 1}')
                        : null,
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    padding: const EdgeInsets.fromLTRB(3, 6, 3, 5),
                    decoration: BoxDecoration(
                      color: reorder.pending
                          ? theme.colorScheme.primary.withValues(alpha: 0.14)
                          : reorder.isDestination
                              ? theme.colorScheme.primary
                                  .withValues(alpha: 0.12)
                              : reorder.isSource
                                  ? theme.colorScheme.primary
                                      .withValues(alpha: 0.07)
                                  : focused
                                      ? theme.colorScheme.primary
                                          .withValues(alpha: 0.08)
                                      : null,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: active
                            ? activeFrameColor
                            : reorder.isSource || reorder.isDestination
                                ? theme.colorScheme.primary
                                : focused
                                    ? theme.colorScheme.outline
                                    : Colors.transparent,
                        width:
                            active || reorder.isSource || reorder.isDestination
                                ? 2
                                : 1,
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
                              child: ChameleonLoadingIndicator(
                                size: math.max(30, markSize),
                                semanticLabel: localizations.activating,
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
                  if (reorder.pending)
                    Positioned(
                      top: 3,
                      left: 12,
                      right: 12,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          key: Key('home-slot-${index + 1}-reorder-progress'),
                          value: MediaQuery.disableAnimationsOf(context)
                              ? 1
                              : null,
                          minHeight: 2,
                        ),
                      ),
                    ),
                ],
              ),
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
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}
