// App frame: wide screens get a navigation rail (like the car), phones a bottom bar with
// a mini player.

import 'package:flutter/material.dart';

import '../l10n.dart';
import '../player.dart';
import 'books.dart';
import 'common.dart';
import 'lists.dart';
import 'now_playing.dart';
import 'pills.dart';
import 'settings.dart';
import 'title_bar.dart';
import 'views.dart';

class Shell extends StatefulWidget {
  final VoidCallback onSignOut;
  const Shell({super.key, required this.onSignOut});
  @override
  State<Shell> createState() => _ShellState();
}

/// The page shown (see `_dest`; 7 the offline titles). Shared with the desktop title bar, whose
/// storage pill and settings button open pages.
final shellPage = ValueNotifier<int>(0);

class _ShellState extends State<Shell> {
  int get index => shellPage.value;
  set index(int i) => shellPage.value = i;

  void _changed() => setState(() {});

  @override
  void initState() {
    super.initState();
    shellPage.addListener(_changed);
  }

  @override
  void dispose() {
    shellPage.removeListener(_changed);
    super.dispose();
  }

  // Wide: 0 now playing, 1 continue, 2 podcasts, 3 audiobooks, 4 music, 5 radio, 6 settings.
  // Phone: the same without "now playing" (opened from the mini player). 7 offline, opened
  // from the indicator at the top.
  static const _dest = [
    (Icons.play_arrow, 'Now playing'),
    (Icons.history, 'Continue'),
    (Icons.podcasts, 'Podcasts'),
    (Icons.menu_book, 'Audiobooks'),
    (Icons.library_music, 'Music'),
    (Icons.radio, 'Radio'),
    (Icons.settings, 'Settings'),
  ];

  Widget _view(int i, bool wide) {
    void opened() => wide ? (index = 0) : _openNowPlaying();
    return switch (i) {
      0 => const NowPlayingView(),
      1 => ContinueView(key: const ValueKey('cont'), onPlay: opened),
      2 => PodcastsView(onPlay: opened),
      3 => BooksView(key: const ValueKey('abs'), onPlay: opened),
      4 => MusicTab(onPlay: opened),
      5 => RadioView(onPlay: opened),
      7 => const OfflineView(),
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
                leading: IconButton(tooltip: t('Back'), onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back)),
                // Linux and Windows: the pills are in the title bar above.
                actions: desktop
                    ? null
                    : [
                        Flexible(
                          child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              reverse: true,
                              child: const Row(mainAxisSize: MainAxisSize.min, children: [CachePill(), StatusPills()])),
                        ),
                        const SizedBox(width: 8),
                      ],
              ),
              body: const SafeArea(top: false, child: NowPlayingView()),
            )));
  }

  /// The top line on Android: icon (wide: name and version as well), Cache, Server, Position, the
  /// offline button and the settings; the moon is in the settings ("Appearance"). Linux and
  /// Windows have the title bar of the window instead (title_bar.dart).
  PreferredSizeWidget? _bar(bool wide) {
    if (desktop) return null;
    final pills = [const CachePill(), const StatusPills()];
    final settings = IconButton(tooltip: t('Settings'), onPressed: () => index = 6, icon: const Icon(Icons.settings));
    return AppBar(
      titleSpacing: 12,
      title: wide
          ? Row(mainAxisSize: MainAxisSize.min, children: [
              lineIcon(context, size: 26),
              const SizedBox(width: 8),
              const Text('audiojoe', style: TextStyle(fontWeight: FontWeight.w800)),
              if (appVersion.isNotEmpty) ...[
                const SizedBox(width: 6),
                Text(appVersion, style: TextStyle(fontSize: 14, color: context.tok.muted, fontWeight: FontWeight.w600)),
              ],
            ])
          // The icon instead of the name: the pills need the width on phones.
          : Semantics(label: 'audiojoe', child: lineIcon(context, size: 30)),
      actions: [
        Flexible(child: SingleChildScrollView(scrollDirection: Axis.horizontal, reverse: true, child: Row(mainAxisSize: MainAxisSize.min, children: pills))),
        IconButton(
          tooltip: t('Offline'),
          isSelected: index == 7,
          onPressed: () => index = 7,
          icon: const Icon(Icons.download_for_offline_outlined),
          selectedIcon: const Icon(Icons.download_for_offline),
        ),
        if (!wide) settings,
        const SizedBox(width: 4),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth >= 720;
        final bar = _bar(wide);
        if (wide) {
          return Scaffold(
            appBar: bar,
            body: Row(children: [
              NavigationRail(
                selectedIndex: index < _dest.length ? index : null,
                labelType: NavigationRailLabelType.all,
                onDestinationSelected: (i) => index = i,
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
              onDestinationSelected: (i) => index = i + 1,
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
                      Text(player.chapterLine.isNotEmpty ? t('Chapter {c}', {'c': player.chapterLine}) : (it.quality?.badge ?? it.subtitle),
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
