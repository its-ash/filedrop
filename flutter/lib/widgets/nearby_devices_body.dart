import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:theme/theme.dart';

import '../models/device.dart';
import '../providers/filedrop_providers.dart';

/// Body-only (no `Scaffold`/`AppBar`) nearby-devices list, extracted from
/// the old `nearby_devices_screen.dart`.
///
/// Used two ways from the Home tab:
///  - Send flow ([onDeviceSelected] set): tapping a device advances to
///    Send Confirmation for that device.
///  - Receive mode ([onDeviceSelected] null): the list is purely
///    informational while the user waits for an incoming request, which
///    surfaces separately as an overlay.
class NearbyDevicesBody extends ConsumerWidget {
  const NearbyDevicesBody({super.key, this.onDeviceSelected, this.emptyTitle, this.emptySubtitle});

  final ValueChanged<Device>? onDeviceSelected;
  final String? emptyTitle;
  final String? emptySubtitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(nearbyDevicesProvider).values.toList();

    if (devices.isEmpty) {
      return Center(
        child: ThemeEmptyState(
          icon: Icons.wifi_tethering,
          title: emptyTitle ?? 'No devices found yet',
          subtitle: emptySubtitle ??
              'FileDrop is broadcasting on your LAN via mDNS. Make sure the '
                  'other device also has FileDrop open.',
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: devices.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) =>
          _DeviceTile(device: devices[index], onTap: onDeviceSelected),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({required this.device, this.onTap});

  final Device device;
  final ValueChanged<Device>? onTap;

  IconData get _platformIcon => switch (device.platform) {
        'android' => Icons.phone_android,
        'ios' => Icons.phone_iphone,
        'macos' => Icons.laptop_mac,
        'windows' => Icons.laptop_windows,
        'linux' => Icons.computer,
        _ => Icons.devices_other,
      };

  @override
  Widget build(BuildContext context) {
    return ThemeCard(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: CircleAvatar(child: Icon(_platformIcon)),
        title: Text(device.name),
        subtitle: Text('${device.address}:${device.port} · ${device.platform}'),
        trailing: device.paired
            ? const Icon(Icons.verified, size: 20)
            : (onTap != null ? const Icon(Icons.chevron_right) : null),
        onTap: onTap == null ? null : () => onTap!(device),
      ),
    );
  }
}
