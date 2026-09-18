import 'package:flutter/material.dart';
import 'package:theme/theme.dart';

/// Settings tab: device/app settings plus, folded in as a "Network"
/// section (merged from the old `network_setup_screen.dart`), the
/// connection-mode configuration that used to be its own screen.
///
/// ASCII mockup reference (spec):
/// ```
/// +----------------------------------+
/// |  Settings                         |
/// |------------------------------------|
/// |  Device Name        Ashvini's Mac |
/// |  Save location       ~/Downloads  |
/// |  Network                          |
/// |    (o) Existing LAN               |
/// |    ( ) No router (direct connect) |
/// |  Clear History                    |
/// |  About FileDrop                   |
/// +----------------------------------+
/// ```
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

enum _NetworkMode { existingLan, noRouter }

class _SettingsScreenState extends State<SettingsScreen> {
  _NetworkMode _mode = _NetworkMode.existingLan;

  static const _platformName = 'android';

  static const _directConnectNote =
      'Android: requires Wi-Fi Direct via android.net.wifi.p2p.WifiP2pManager, '
      'callable only from Kotlin through a Flutter platform channel. Not wired up '
      'in this pass — see rust/filedrop-core/src/networking/mode.rs.';

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        const SliverAppBar.large(title: Text('Settings')),
        SliverPadding(
          padding: const EdgeInsets.all(20),
          sliver: SliverList.list(children: [
            ThemeCard(
              margin: EdgeInsets.zero,
              child: Column(
                children: const [
                  ListTile(
                    leading: Icon(Icons.badge_outlined),
                    title: Text('Device Name'),
                    subtitle: Text('This device\'s name as shown to peers'),
                  ),
                  Divider(height: 1),
                  ListTile(
                    leading: Icon(Icons.folder_outlined),
                    title: Text('Save Location'),
                    subtitle: Text('Where received files are stored'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            const ThemeSectionHeader(
              title: 'Network',
              subtitle: 'LAN discovery and direct-connect mode',
            ),
            const SizedBox(height: 8),
            ThemeCard(
              margin: EdgeInsets.zero,
              child: Column(
                children: [
                  RadioGroup<_NetworkMode>(
                    groupValue: _mode,
                    onChanged: (v) => setState(() => _mode = v!),
                    child: const Column(
                      children: [
                        RadioListTile<_NetworkMode>(
                          value: _NetworkMode.existingLan,
                          title: Text('Existing LAN'),
                          subtitle: Text('mDNS/DNS-SD discovery with UDP broadcast fallback.'),
                        ),
                        RadioListTile<_NetworkMode>(
                          value: _NetworkMode.noRouter,
                          title: Text('No router (direct connect)'),
                          subtitle: Text('Wi-Fi Direct / local-only hotspot between two devices.'),
                        ),
                      ],
                    ),
                  ),
                  if (_mode == _NetworkMode.noRouter)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline, color: Theme.of(context).colorScheme.primary),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(_directConnectNote, style: AppTypography.bodyMedium),
                          ),
                        ],
                      ),
                    ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.devices),
                    title: const Text('Platform'),
                    subtitle: const Text(_platformName),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            ThemeCard(
              margin: EdgeInsets.zero,
              child: ListTile(
                leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
                title: Text('Clear History', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                onTap: () {},
              ),
            ),
            const SizedBox(height: 20),
            const ThemeCard(
              margin: EdgeInsets.zero,
              child: ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('About FileDrop'),
                subtitle: Text('v0.1.0 · Local-first, no cloud, no accounts'),
              ),
            ),
          ]),
        ),
      ],
    );
  }
}
