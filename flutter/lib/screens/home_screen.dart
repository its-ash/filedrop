import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:theme/theme.dart';

import '../models/transfer.dart';
import '../providers/filedrop_providers.dart';
import '../widgets/active_transfers_list.dart';
import '../widgets/file_picker_body.dart';
import '../widgets/nearby_devices_body.dart';
import '../widgets/send_confirmation_body.dart';
import 'settings_screen.dart';
import 'transfer_history_screen.dart';

/// Home: two big choices, Send and Receive. Nothing network-related
/// (discovery, server, Wi-Fi Direct) runs until one is picked.
///
/// Flow when there is no active transfer ([HomeFlowStage]):
///  - Send: pick files -> transport is detected automatically (Wi-Fi if the
///    phone is on Wi-Fi, otherwise Wi-Fi Direct) -> pick device -> confirm.
///  - Receive: on Wi-Fi start the server on the LAN, otherwise start the
///    Wi-Fi Direct side.
/// Leaving either screen stops discovery, the server and any direct link.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasActiveTransfers = ref.watch(activeTransfersProvider).isNotEmpty;

    if (hasActiveTransfers) {
      return const _ActiveTransfersView();
    }

    final stage = ref.watch(homeFlowProvider.select((s) => s.stage));
    return switch (stage) {
      HomeFlowStage.idle => const _IdleView(),
      HomeFlowStage.filePicker => const _FilePickerView(),
      HomeFlowStage.deviceSelectSend => const _DeviceSelectSendView(),
      HomeFlowStage.confirmSend => const _ConfirmSendView(),
      HomeFlowStage.receiveMode => const _ReceiveModeView(),
    };
  }
}

/// One or more transfers in flight (or just finished).
class _ActiveTransfersView extends ConsumerWidget {
  const _ActiveTransfersView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inFlight = ref
        .watch(activeTransfersProvider)
        .values
        .any(
          (t) =>
              t.status == TransferStatus.inProgress ||
              t.status == TransferStatus.paused,
        );
    return Scaffold(
      appBar: UiAppBar(
        title: 'Transfers',
        back: false,
        actions: [
          if (!inFlight)
            UiButton(
              'Done',
              variant: UiButtonVariant.ghost,
              onPressed: () {
                ref.read(activeTransfersProvider.notifier).clearFinished();
                ref.read(homeFlowProvider.notifier).reset();
              },
            ),
        ],
      ),
      body: const ActiveTransfersList(),
    );
  }
}

/// Idle: Send / Receive, nothing else.
class _IdleView extends ConsumerWidget {
  const _IdleView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flow = ref.read(homeFlowProvider.notifier);
    return Scaffold(
      appBar: UiAppBar(
        title: 'FileDrop',
        back: false,
        actions: [
          UiIconButton(
            Icons.history,
            tooltip: 'History',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: TransferHistoryScreen()),
              ),
            ),
          ),
          UiIconButton(
            Icons.settings_outlined,
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Expanded(
                child: _ChoiceCard(
                  icon: Icons.upload_rounded,
                  title: 'Send',
                  subtitle: 'Pick files and send them to a nearby device',
                  onTap: flow.startSend,
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: _ChoiceCard(
                  icon: Icons.download_rounded,
                  title: 'Receive',
                  subtitle: 'Get files from a nearby device',
                  onTap: flow.startReceive,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: UiCard(
        onTap: onTap,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            UiIconBox(icon, size: 72),
            const SizedBox(height: 20),
            Text(title, style: context.text.headlineMedium),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: context.text.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

/// Shared scaffold for the Send/Receive screens: back leaves the flow.
class _FlowScaffold extends ConsumerWidget {
  const _FlowScaffold({required this.title, required this.body});

  final String title;
  final Widget body;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flow = ref.read(homeFlowProvider.notifier);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) flow.back();
      },
      child: Scaffold(
        appBar: UiAppBar(title: title, onBack: flow.back),
        body: body,
      ),
    );
  }
}

/// One short line saying which transport is used.
class _TransportLine extends StatelessWidget {
  const _TransportLine(this.transport);

  final TransferTransport? transport;

  @override
  Widget build(BuildContext context) {
    final (icon, text) = switch (transport) {
      TransferTransport.wifi => (Icons.wifi, 'Using Wi-Fi'),
      TransferTransport.direct => (
        Icons.wifi_tethering,
        'Using Wi-Fi Direct (no Wi-Fi network)',
      ),
      null => (Icons.sync, 'Checking connection…'),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          Icon(icon, size: 18, color: context.colors.accent),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: context.text.bodyMedium)),
        ],
      ),
    );
  }
}

/// Send, step 1: pick files.
class _FilePickerView extends ConsumerWidget {
  const _FilePickerView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _FlowScaffold(
      title: 'Send',
      body: FilePickerBody(
        onContinue: (paths) =>
            ref.read(homeFlowProvider.notifier).filesPicked(paths),
      ),
    );
  }
}

/// Send, step 2: the transport is detected automatically, then nearby
/// devices are listed.
class _DeviceSelectSendView extends ConsumerWidget {
  const _DeviceSelectSendView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final send = ref.watch(homeFlowProvider.select((s) => s.send));
    final flow = ref.read(homeFlowProvider.notifier);

    final Widget content = switch (send.stage) {
      SendLinkStage.checking => _BusyBody(
        send.transport == TransferTransport.direct
            ? 'Connecting directly to a nearby device…'
            : 'Checking your network…',
      ),
      SendLinkStage.needWifi => _TurnOnWifiBody(
        onOpen: flow.openWifiPanel,
        onRetry: flow.retry,
      ),
      SendLinkStage.error => UiErrorState(
        title: 'Couldn\'t connect',
        message: send.errorMessage ?? 'Wi-Fi Direct failed.',
        icon: Icons.wifi_tethering_error_rounded,
        onRetry: flow.retry,
      ),
      SendLinkStage.ready => NearbyDevicesBody(
        onDeviceSelected: flow.deviceSelected,
        emptyTitle: 'Looking for devices…',
        emptySubtitle: 'Ask the other person to open Receive in FileDrop.',
      ),
    };

    return _FlowScaffold(
      title: 'Send to',
      body: Column(
        children: [
          _TransportLine(send.transport),
          Expanded(child: content),
        ],
      ),
    );
  }
}

/// Send, step 3: confirm and dispatch. The link is kept up so the
/// transfer can finish; the active-transfer view takes over.
class _ConfirmSendView extends ConsumerWidget {
  const _ConfirmSendView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flow = ref.watch(homeFlowProvider);
    final device = flow.device;

    return _FlowScaffold(
      title: 'Send',
      body: device == null
          ? const SizedBox.shrink()
          : SendConfirmationBody(
              device: device,
              filePaths: flow.filePaths,
              onSent: () =>
                  ref.read(homeFlowProvider.notifier).reset(keepLink: true),
            ),
    );
  }
}

/// Receive: Wi-Fi server on the LAN, or the Wi-Fi Direct side. Incoming
/// requests arrive via the [pairingRequestsProvider] overlay (main.dart).
class _ReceiveModeView extends ConsumerWidget {
  const _ReceiveModeView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final receive = ref.watch(homeFlowProvider.select((s) => s.receive));
    final flow = ref.read(homeFlowProvider.notifier);

    final Widget content = switch (receive.stage) {
      ReceiveStage.checkingLan => const _BusyBody('Checking your network…'),
      ReceiveStage.needWifi => _TurnOnWifiBody(
        onOpen: flow.openWifiPanel,
        onRetry: flow.retry,
      ),
      ReceiveStage.creatingGroup => const _BusyBody(
        'Starting Wi-Fi Direct…',
      ),
      ReceiveStage.wifiDirectError => UiErrorState(
        title: 'Couldn\'t start Wi-Fi Direct',
        message:
            receive.errorMessage ??
            'An unknown error occurred while setting up Wi-Fi Direct.',
        icon: Icons.wifi_tethering_error_rounded,
        onRetry: flow.retry,
      ),
      ReceiveStage.waiting => _WaitingToReceiveBody(address: receive.address),
    };

    return _FlowScaffold(
      title: 'Receive',
      body: Column(
        children: [
          _TransportLine(
            receive.stage == ReceiveStage.waiting ? receive.transport : null,
          ),
          Expanded(child: content),
        ],
      ),
    );
  }
}

class _BusyBody extends StatelessWidget {
  const _BusyBody(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const UiSpinner(size: 40),
          const SizedBox(height: 20),
          Text(message),
        ],
      ),
    );
  }
}

/// Wi-Fi radio is off. Android 10+ apps cannot switch it on directly, so
/// this opens the system Wi-Fi panel.
class _TurnOnWifiBody extends StatelessWidget {
  const _TurnOnWifiBody({required this.onOpen, required this.onRetry});

  final VoidCallback onOpen;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.wifi_off_outlined,
              size: 56,
              color: context.colors.accent,
            ),
            const SizedBox(height: 20),
            Text('Turn on Wi-Fi', style: context.text.titleMedium),
            const SizedBox(height: 8),
            const Text(
              'Wi-Fi is off. Turn it on to connect to a nearby device.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            UiButton('Open Wi-Fi settings', icon: Icons.wifi, onPressed: onOpen),
            const SizedBox(height: 8),
            UiButton(
              'I turned it on',
              variant: UiButtonVariant.ghost,
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}

/// Waiting to receive: shows this device's address and a spinner.
class _WaitingToReceiveBody extends StatelessWidget {
  const _WaitingToReceiveBody({this.address});

  final String? address;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const UiSpinner(size: 56),
            const SizedBox(height: 24),
            Text('Waiting for incoming files…', style: context.text.titleMedium),
            const SizedBox(height: 8),
            const Text(
              'Keep this screen open. You\'ll be asked here when another '
              'device wants to send you files.',
              textAlign: TextAlign.center,
            ),
            if (address != null) ...[
              const SizedBox(height: 20),
              UiCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.lan_outlined, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      address!,
                      style: const TextStyle(
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 8),
                    UiIconButton(
                      Icons.copy_outlined,
                      tooltip: 'Copy address',
                      size: UiSize.sm,
                      onPressed: () =>
                          Clipboard.setData(ClipboardData(text: address!)),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
