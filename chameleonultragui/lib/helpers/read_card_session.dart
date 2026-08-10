import 'package:chameleonultragui/helpers/card_info.dart';
import 'package:chameleonultragui/helpers/mifare_classic/types.dart';
import 'package:chameleonultragui/helpers/mifare_ultralight/types.dart';

export 'package:chameleonultragui/helpers/card_info.dart';
export 'package:chameleonultragui/helpers/mifare_classic/types.dart';
export 'package:chameleonultragui/helpers/mifare_ultralight/types.dart';

/// Current Read Card result for the active connected-device session.
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
