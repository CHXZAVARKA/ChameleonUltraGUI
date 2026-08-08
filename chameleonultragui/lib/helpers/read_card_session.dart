import 'dart:typed_data';

import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/recovery.dart';

enum MifareClassicState {
  none,
  checkKeys,
  checkKeysOngoing,
  recovery,
  recoveryOngoing,
  dump,
  dumpOngoing,
  save
}

// cardExist true because we don't show error to user if nothing is done
class HFCardInfo {
  String uid;
  String sak;
  String atqa;
  String tech;
  String ats;
  TagType type;
  bool cardExist;

  HFCardInfo(
      {this.uid = '',
      this.sak = '',
      this.atqa = '',
      this.tech = '',
      this.ats = '',
      this.type = TagType.unknown,
      this.cardExist = true});
}

class LFCardInfo {
  LFCard? card;
  bool cardExist;

  LFCardInfo({this.cardExist = true});
}

class MifareClassicInfo {
  bool isEV1;
  MifareClassicRecovery? recovery;
  MifareClassicType type;
  MifareClassicState state;
  NTLevel? ntLevel;
  bool? hasBackdoor;

  MifareClassicInfo({
    MifareClassicRecovery? recovery,
    this.isEV1 = false,
    this.type = MifareClassicType.none,
    this.state = MifareClassicState.none,
    NTLevel? ntLevel,
    bool? hasBackdoor,
  });
}

class MifareUltralightInfo {
  Uint8List? version;
  Uint8List? signature;

  MifareUltralightInfo();
}

/// Current Read Card result for the lifetime of the application session.
///
/// RF scan timers and progress remain owned by the page widget and are not part
/// of this model.
class ReadCardSession {
  String dumpName = '';
  HFCardInfo hfInfo = HFCardInfo();
  LFCardInfo lfInfo = LFCardInfo();
  MifareClassicInfo mfcInfo = MifareClassicInfo();
  MifareUltralightInfo mfuInfo = MifareUltralightInfo();
}
