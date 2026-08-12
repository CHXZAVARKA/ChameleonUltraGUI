import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Configures the test view and restores every overridden metric afterwards.
void setTestViewport(
  WidgetTester tester, {
  required Size size,
  double? devicePixelRatio = 1,
  double? textScaleFactor,
}) {
  final view = tester.view;
  final platformDispatcher = tester.platformDispatcher;

  addTearDown(() {
    view.resetPhysicalSize();
    if (devicePixelRatio != null) {
      view.resetDevicePixelRatio();
    }
    if (textScaleFactor != null) {
      platformDispatcher.clearTextScaleFactorTestValue();
    }
  });

  view.physicalSize = size;
  if (devicePixelRatio != null) {
    view.devicePixelRatio = devicePixelRatio;
  }
  if (textScaleFactor != null) {
    platformDispatcher.textScaleFactorTestValue = textScaleFactor;
  }
}
