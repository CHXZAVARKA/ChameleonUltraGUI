import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/gui/component/chameleon_loading_indicator.dart';
import 'package:chameleonultragui/status/connection_readiness.dart';
import 'package:flutter/material.dart';

class ConnectionReadinessCard extends StatelessWidget {
  const ConnectionReadinessCard({
    super.key,
    required this.readiness,
    this.compact = false,
  });

  final ConnectionReadinessTracker readiness;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: readiness,
      builder: (context, _) {
        final snapshot = readiness.snapshot;
        final localizations = AppLocalizations.of(context)!;
        final label = _stageLabel(localizations, snapshot);
        final error = _errorLabel(localizations, snapshot.errorCategory);
        if (_stageIsInProgress(snapshot.stage)) {
          return Semantics(
            key: const Key('connection-readiness'),
            container: true,
            liveRegion: true,
            label: label,
            excludeSemantics: true,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: 48,
                maxWidth: compact ? 560 : 420,
              ),
              child: compact
                  ? SizedBox(
                      height: 48,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          ChameleonLoadingIndicator(
                            size: 36,
                            semanticLabel: label,
                          ),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              label,
                              key: const Key('connection-readiness-label'),
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                        ],
                      ),
                    )
                  : Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ChameleonLoadingIndicator(
                            size: 72,
                            semanticLabel: label,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            label,
                            key: const Key('connection-readiness-label'),
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ],
                      ),
                    ),
            ),
          );
        }
        return Semantics(
          key: const Key('connection-readiness'),
          container: true,
          liveRegion: true,
          label: error == null ? label : '$label. $error',
          excludeSemantics: true,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: 48,
              maxWidth: compact ? 560 : 420,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: _backgroundColor(context, snapshot.stage),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 12 : 18,
                  vertical: 10,
                ),
                child: Row(
                  mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
                  children: [
                    Icon(
                      _stageIcon(snapshot.stage),
                      key: const Key('connection-readiness-icon'),
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            label,
                            key: const Key('connection-readiness-label'),
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          if (error != null)
                            Text(
                              error,
                              key: const Key('connection-readiness-error'),
                              style: Theme.of(context).textTheme.bodySmall,
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
      },
    );
  }
}

bool _stageIsInProgress(ConnectionReadinessStage stage) => switch (stage) {
      ConnectionReadinessStage.discovering ||
      ConnectionReadinessStage.connectingTransport ||
      ConnectionReadinessStage.waitingForProtocol ||
      ConnectionReadinessStage.loadingStatus =>
        true,
      _ => false,
    };

String _stageLabel(
  AppLocalizations localizations,
  ConnectionReadinessSnapshot snapshot,
) =>
    switch (snapshot.stage) {
      ConnectionReadinessStage.disconnected =>
        localizations.connection_stage_disconnected,
      ConnectionReadinessStage.discovering =>
        localizations.connection_stage_discovering,
      ConnectionReadinessStage.connectingTransport =>
        snapshot.transport == ConnectionType.ble
            ? localizations.connection_stage_connecting_bluetooth
            : localizations.connection_stage_connecting_usb,
      ConnectionReadinessStage.waitingForProtocol =>
        localizations.connection_stage_waiting_protocol,
      ConnectionReadinessStage.loadingStatus =>
        localizations.connection_stage_loading_status,
      ConnectionReadinessStage.ready => localizations.connection_stage_ready,
      ConnectionReadinessStage.degraded =>
        localizations.connection_stage_degraded,
      ConnectionReadinessStage.failed => localizations.connection_stage_failed,
    };

String? _errorLabel(
  AppLocalizations localizations,
  ConnectionReadinessErrorCategory? category,
) =>
    switch (category) {
      null => null,
      ConnectionReadinessErrorCategory.timeout =>
        localizations.connection_error_timeout,
      ConnectionReadinessErrorCategory.transport =>
        localizations.connection_error_transport,
      ConnectionReadinessErrorCategory.protocol =>
        localizations.connection_error_protocol,
      ConnectionReadinessErrorCategory.status =>
        localizations.connection_error_status,
      ConnectionReadinessErrorCategory.disconnected =>
        localizations.connection_stage_disconnected,
      ConnectionReadinessErrorCategory.unknown =>
        localizations.connection_error_unknown,
    };

IconData _stageIcon(ConnectionReadinessStage stage) => switch (stage) {
      ConnectionReadinessStage.disconnected => Icons.link_off,
      ConnectionReadinessStage.discovering => Icons.radar,
      ConnectionReadinessStage.connectingTransport => Icons.link,
      ConnectionReadinessStage.waitingForProtocol => Icons.sync_alt,
      ConnectionReadinessStage.loadingStatus => Icons.downloading,
      ConnectionReadinessStage.ready => Icons.check_circle_outline,
      ConnectionReadinessStage.degraded => Icons.info_outline,
      ConnectionReadinessStage.failed => Icons.error_outline,
    };

Color _backgroundColor(BuildContext context, ConnectionReadinessStage stage) {
  final colors = Theme.of(context).colorScheme;
  return switch (stage) {
    ConnectionReadinessStage.failed => colors.errorContainer,
    ConnectionReadinessStage.degraded => colors.tertiaryContainer,
    ConnectionReadinessStage.ready => colors.primaryContainer,
    _ => colors.surfaceContainerHighest,
  };
}
