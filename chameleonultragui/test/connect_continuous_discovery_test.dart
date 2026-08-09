import 'dart:typed_data';

import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/page/connect.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'discovery keeps scanning after a result and accumulates multiple devices',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'auto_scan_enabled': true,
        'auto_connect_first_found': false,
      });
      final serial = _DiscoverySerial(
        log: Logger(output: MemoryOutput()),
        scans: const [
          [
            Chameleon(
              port: 'device-a',
              device: ChameleonDevice.ultra,
              type: ConnectionType.ble,
              dfu: false,
            ),
          ],
          [
            Chameleon(
              port: 'device-b',
              device: ChameleonDevice.lite,
              type: ConnectionType.ble,
              dfu: false,
            ),
          ],
        ],
      );
      final preferences = SharedPreferencesProvider();
      await preferences.load();
      final appState = ChameleonGUIState(preferences)
        ..connector = serial
        ..log = serial.log;

      await tester.pumpWidget(
        ChangeNotifierProvider<ChameleonGUIState>.value(
          value: appState,
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ConnectPage(
              autoScanInterval: Duration(milliseconds: 20),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(serial.scanCalls, 1);
      expect(find.text('device-a'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump();

      expect(serial.scanCalls, 2);
      expect(find.text('device-a'), findsOneWidget);
      expect(find.text('device-b'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump();

      expect(serial.scanCalls, 4);
      expect(find.text('device-a'), findsNothing);
      expect(find.text('device-b'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

class _DiscoverySerial extends AbstractSerial {
  _DiscoverySerial({required super.log, required this.scans});

  final List<List<Chameleon>> scans;
  int scanCalls = 0;

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async {
    final index = scanCalls < scans.length ? scanCalls : scans.length - 1;
    scanCalls++;
    return scans[index];
  }

  @override
  bool isManualConnectionSupported() => false;

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async => false;

  @override
  Future<bool> write(Uint8List command, {bool firmware = false}) async => false;
}
