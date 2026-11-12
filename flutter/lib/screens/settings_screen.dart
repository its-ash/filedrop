import 'package:flutter/material.dart';
import 'package:theme/theme.dart';

/// Settings screen, opened from the home screen's app bar.
///
/// The network is chosen automatically (Wi-Fi when available, otherwise
/// Wi-Fi Direct), so there is no network mode setting here. The last
/// groups are the shared Appearance, Updates and Developer sections.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const UiAppBar(title: 'Settings'),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const UiCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                ListTile(
                  leading: Icon(Icons.wifi),
                  title: Text('Network'),
                  subtitle: Text(
                    'Chosen automatically: Wi-Fi when connected, otherwise '
                    'a direct phone-to-phone connection.',
                  ),
                ),
                UiDivider(),
                ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('About FileDrop'),
                  subtitle: Text('Local-first, no cloud, no accounts'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const UiAppearanceSection(),
          const SizedBox(height: 20),
          // No INTERNET permission in the main manifest: the row opens the
          // latest APK download in the browser.
          const UiUpdateSection(storeId: 'filedrop', checkForUpdates: false),
          const SizedBox(height: 20),
          const UiDeveloperSection(),
        ],
      ),
    );
  }
}
