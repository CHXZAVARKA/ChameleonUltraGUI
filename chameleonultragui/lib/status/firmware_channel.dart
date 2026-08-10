enum FirmwareChannel { official, custom }

extension FirmwareChannelRepository on FirmwareChannel {
  String get repository => switch (this) {
        FirmwareChannel.official => 'RfidResearchGroup/ChameleonUltra',
        FirmwareChannel.custom => 'CHXZAVARKA/ChameleonUltra',
      };

  bool get usesActionsArtifacts => this == FirmwareChannel.official;
}
