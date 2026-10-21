import 'package:flutter/material.dart';

/// App shell that keeps both tabs alive while switching between them.
class HomeTabScaffold extends StatelessWidget {
  const HomeTabScaffold({
    super.key,
    required this.selectedTab,
    required this.onTabSelected,
    required this.generateTab,
    required this.libraryTab,
    required this.isPlaying,
    required this.onStopPlayback,
  });

  static const Key generateTabKey = ValueKey<String>('home-tab-generate');
  static const Key libraryTabKey = ValueKey<String>('home-tab-library');
  static const Key stopPlaybackKey = ValueKey<String>('stop-playback');

  final int selectedTab;
  final ValueChanged<int> onTabSelected;
  final Widget generateTab;
  final Widget libraryTab;
  final bool isPlaying;
  final VoidCallback onStopPlayback;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(selectedTab == 0 ? 'Vietnamese Shadowing' : 'Library'),
        actions: [
          if (isPlaying)
            IconButton(
              key: stopPlaybackKey,
              tooltip: 'Stop playback',
              onPressed: onStopPlayback,
              icon: const Icon(Icons.stop),
            ),
        ],
      ),
      body: IndexedStack(
        index: selectedTab,
        children: [generateTab, libraryTab],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedTab,
        onDestinationSelected: onTabSelected,
        destinations: const [
          NavigationDestination(
            key: generateTabKey,
            icon: Icon(Icons.record_voice_over_outlined),
            selectedIcon: Icon(Icons.record_voice_over),
            label: 'Generate',
          ),
          NavigationDestination(
            key: libraryTabKey,
            icon: Icon(Icons.library_music_outlined),
            selectedIcon: Icon(Icons.library_music),
            label: 'Library',
          ),
        ],
      ),
    );
  }
}
