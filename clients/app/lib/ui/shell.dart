// App frame: wide screens get a navigation rail (like the car), phones a bottom bar with
// a mini player.

import 'package:flutter/material.dart';

import '../l10n.dart';
import '../player.dart';
import 'common.dart';
import 'now_playing.dart';
import 'settings.dart';
import 'views.dart';

class Shell extends StatefulWidget {
  final VoidCallback onSignOut;
  const Shell({super.key, required this.onSignOut});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int index = 0;

  // Wide: 0 now playing, 1 continue, 2 podcasts, 3 audiobooks, 4 music, 5 offline, 6 settings.
  // Phone: the same without "now playing" (opened from the mini player).
  static const _dest = [
    (Icons.play_arrow, 'Now playing'),
    (Icons.history, 'Continue'),
    (Icons.podcasts, 'Podcasts'),
    (Icons.menu_book, 'Audiobooks'),
    (Icons.library_music, 'Music'),
    (Icons.download_for_offline, 'Offline'),
    (Icons.settings, 'Settings'),
  ];

  Widget _view(int i, bool wide) {
    void opened() => wide ? setState(() => index = 0) : _openNowPlaying();
    return switch (i) {
      0 => const NowPlayingView(),
      1 => ContinueView(key: const ValueKey('cont'), onPlay: opened),
      2 => PodcastsView(onPlay: opened),
      3 => BrowseView(key: const ValueKey('abs'), kinds: const ['audiobookshelf'], onPlay: opened),
      4 => MusicTab(onPlay: opened),
      5 => const OfflineView(),
      _ => SettingsView(onSignOut: widget.onSignOut),
    };
  }

  void _openNowPlaying() {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => Scaffold(
              // No text input here: never shrink for a keyboard left over from a search field.
              resizeToAvoidBottomInset: false,
              appBar: AppBar(
                leading: IconButton(tooltip: t('Close'), onPressed: () => Navigator.pop(context), icon: const Icon(Icons.keyboard_arrow_down, size: 32)),
                actions: const [StatusPills(), SizedBox(width: 8)],
              ),
              body: const SafeArea(top: false, child: NowPlayingView()),
            )));
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth >= 720;
        final bar = AppBar(
          // The app icon instead of the name: the status pills need the width on phones.
          title: wide
              ? const Text('audiojoe', style: TextStyle(fontWeight: FontWeight.w800))
              : Semantics(label: 'audiojoe', child: Image.asset('assets/icon.png', height: 36)),
          actions: [
            Flexible(child: SingleChildScrollView(scrollDirection: Axis.horizontal, reverse: true, child: StatusPills(compact: !wide))),
            const AppearanceButton(),
            if (!wide) IconButton(onPressed: () => setState(() => index = 6), icon: const Icon(Icons.settings)),
            const SizedBox(width: 4),
          ],
        );
        if (wide) {
          return Scaffold(
            appBar: bar,
            body: Row(children: [
              NavigationRail(
                selectedIndex: index,
                labelType: NavigationRailLabelType.all,
                onDestinationSelected: (i) => setState(() => index = i),
                destinations: [for (final d in _dest) NavigationRailDestination(icon: Icon(d.$1), label: Text(t(d.$2)))],
              ),
              const VerticalDivider(width: 2),
              Expanded(child: _view(index, true)),
            ]),
          );
        }
        final phoneIndex = index == 0 ? 1 : index; // "now playing" is the mini player
        return Scaffold(
          appBar: bar,
          body: _view(phoneIndex, false),
          bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
            MiniPlayer(onOpen: _openNowPlaying),
            NavigationBar(
              selectedIndex: (phoneIndex - 1).clamp(0, 4),
              onDestinationSelected: (i) => setState(() => index = i + 1),
              destinations: [for (final d in _dest.sublist(1, 6)) NavigationDestination(icon: Icon(d.$1), label: t(d.$2))],
            ),
          ]),
        );
      });
}

class MiniPlayer extends StatelessWidget {
  final VoidCallback onOpen;
  const MiniPlayer({super.key, required this.onOpen});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: player,
        builder: (context, _) {
          final it = player.item;
          if (it == null) return const SizedBox.shrink();
          return Material(
            color: Theme.of(context).colorScheme.surface,
            child: InkWell(
              onTap: onOpen,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                child: Row(children: [
                  CoverThumb(image: it.image, label: it.subtitle.isEmpty ? it.title : it.subtitle),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(it.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text(player.chapter.isNotEmpty ? player.chapter : (it.quality?.badge ?? it.subtitle),
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: context.tok.muted, fontSize: 13)),
                    ]),
                  ),
                  IconButton.filled(iconSize: 30, onPressed: player.toggle, icon: Icon(player.playing ? Icons.pause : Icons.play_arrow)),
                ]),
              ),
            ),
          );
        },
      );
}
