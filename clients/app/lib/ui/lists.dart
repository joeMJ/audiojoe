// Continue: three lists – podcasts, audiobooks, music – in the user's order on all devices.
// Started episodes and books come in at the top by themselves, "Next" appends at the end,
// the bin marks as heard (music: takes the album out). After an item the next one plays.

import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../downloads.dart';
import '../l10n.dart';
import '../models.dart';
import '../player.dart';
import '../remote.dart';
import '../store.dart';
import '../sync.dart';
import 'common.dart';
import 'details.dart';
import 'views.dart';

class ListEntry {
  final String key, title, subtitle, device;
  final int positionMs;
  final int? durationMs;
  final String? updatedAt;
  ListEntry(Map<String, dynamic> j)
      : key = j['key'] as String,
        title = (j['title'] ?? '') as String,
        subtitle = (j['subtitle'] ?? '') as String,
        device = (j['device'] ?? '') as String,
        positionMs = (j['position_ms'] ?? 0) as int,
        durationMs = j['duration_ms'] as int?,
        updatedAt = j['updated_at'] as String?;
}

String listOf(Item it) => it.kind == 'episode' ? 'podcasts' : it.kind == 'book' ? 'books' : 'music';

/// Keys of audiobooks: Audiobookshelf, Jellyfin/Emby folders, Plex albums.
bool isBookKey(String key) => key.startsWith('abs:') || key.startsWith('jbook:') || key.startsWith('pbook:');

Future<List<ListEntry>> loadList(String list) async =>
    [for (final j in await api.call('GET', '/lists/$list') as List) ListEntry((j as Map).cast<String, dynamic>())];

/// Tracks of an album entry ("jellyfin:2:abc" → browse parent abc of source 2).
Future<List<Item>> albumTracks(String key) async {
  final p = key.split(':');
  final res = await api.call('GET', '/sources/${p[1]}/browse', query: {'parent': p[2], 'limit': '500'});
  return itemsOf(res['items']).where((i) => i.kind == 'track').toList();
}

Future<void> playEntry(BuildContext? context, String list, ListEntry e, VoidCallback? onPlay) async {
  final from = (list: list, key: e.key);
  if (list == 'music') {
    final tracks = await albumTracks(e.key);
    if (tracks.isEmpty) return;
    context != null && context.mounted ? await startPlayback(context, tracks, 0, onPlay, from) : await player.play(tracks, 0, from);
    return;
  }
  final it = Item(key: e.key, kind: list == 'podcasts' ? 'episode' : 'book', title: e.title, subtitle: e.subtitle, image: coverOf(e.key));
  context != null && context.mounted ? await startPlayback(context, [it], 0, onPlay, from) : await player.play([it], 0, from);
}

/// Hooks the player up: at the end of an item the next entry of the same list plays.
void connectLists() {
  player.nextAfter = (e) async {
    final list = await loadList(e.list);
    final i = list.indexWhere((x) => x.key == e.key);
    if (i < 0) return null;
    if (e.list == 'music') unawaited(api.call('DELETE', '/lists/music/${Uri.encodeComponent(e.key)}').catchError((_) {}));
    if (i + 1 >= list.length) return null;
    final next = list[i + 1];
    return () async {
      await playEntry(null, e.list, next, null);
      // just_audio's play() above already started it.
    };
  };
}

/// "Next": appends the item (an album as one entry) at the end of its continue list.
class NextButton extends StatefulWidget {
  final Item item;
  const NextButton(this.item, {super.key});
  @override
  State<NextButton> createState() => _NextButtonState();
}

class _NextButtonState extends State<NextButton> {
  bool done = false;

  Future<void> _add() async {
    final it = widget.item;
    try {
      await api.call('POST', '/lists/${listOf(it)}', body: {'key': it.key, 'title': it.title, 'subtitle': it.subtitle});
      setState(() => done = true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${t('Error')}: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    // Phones: an icon (the row is narrow); wide screens: the word.
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final icon = Icon(done ? Icons.playlist_add_check : Icons.playlist_add);
    if (!wide) return IconButton(tooltip: t('Added to Next'), onPressed: done ? null : _add, icon: icon);
    return OutlinedButton.icon(onPressed: done ? null : _add, icon: icon, label: Text(t('Add to Next')));
  }
}

const _lists = ['podcasts', 'books', 'music'];

class ContinueView extends StatefulWidget {
  final VoidCallback onPlay;
  const ContinueView({super.key, required this.onPlay});
  @override
  State<ContinueView> createState() => _ContinueViewState();
}

class _ContinueViewState extends State<ContinueView> {
  String list = (Stores.device.get('continue')?['list'] as String?) ?? 'podcasts';
  List<ListEntry>? entries;
  Object? error;
  final _subs = <StreamSubscription>[];

  @override
  void initState() {
    super.initState();
    _load();
    _subs.add(sync.lists.listen((l) => l == list ? _load() : null));
    _subs.add(sync.remote.listen((_) => _load()));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final l = list;
    try {
      final got = await loadList(l);
      if (mounted && l == list) setState(() => (entries = got, error = null));
    } catch (e) {
      // Offline: what this device knows (started, unfinished).
      final local = Stores.positions.data.entries
          .where((x) => l == 'podcasts' ? x.key.startsWith('episode:') : l == 'books' && isBookKey(x.key))
          .map((x) => Playback.fromJson(x.value, key: x.key))
          .where((p) => !p.finished && p.positionMs > 0)
          .toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      if (mounted && l == list) {
        setState(() => entries = [
              for (final p in local)
                ListEntry({'key': p.key, 'title': p.title, 'subtitle': p.subtitle, 'device': p.device, 'position_ms': p.positionMs,
                  'duration_ms': p.durationMs, 'updated_at': p.updatedAt}),
            ]);
      }
    }
  }

  void _switch(String l) {
    Stores.device.put('continue', {'list': l});
    setState(() => (list = l, entries = null));
    _load();
  }

  Future<void> _reorder(int from, int to) async {
    final l = [...entries!];
    l.insert(to, l.removeAt(from));
    setState(() => entries = l);
    try {
      await api.call('PUT', '/lists/$list', body: [for (final e in l) e.key]);
    } catch (_) {
      _load();
    }
  }

  Future<void> _bin(ListEntry e) async {
    final l = list, keys = [for (final x in entries!) x.key];
    setState(() => entries = entries!.where((x) => x.key != e.key).toList());
    String now() => DateTime.now().toUtc().toIso8601String();
    Playback state(bool finished) => Playback(key: e.key, positionMs: e.positionMs, durationMs: e.durationMs, finished: finished,
        title: e.title, subtitle: e.subtitle, device: api.device, updatedAt: now());
    try {
      if (l == 'music') {
        await api.call('DELETE', '/lists/music/${Uri.encodeComponent(e.key)}');
      } else {
        sync.savePosition(state(true));
      }
    } catch (_) {}
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 6),
      persist: false,
      content: Text(l == 'music' ? t('Removed from the list') : t('Marked as heard')),
      action: SnackBarAction(
        label: t('Undo'),
        onPressed: () async {
          if (l != 'music') sync.savePosition(state(false));
          try {
            await api.call('POST', '/lists/$l', body: {'key': e.key, 'title': e.title, 'subtitle': e.subtitle});
            await api.call('PUT', '/lists/$l', body: keys);
          } catch (_) {}
          if (mounted && list == l) _load();
        },
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final k = context.tok;
    final seg = Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Center(
        child: SegmentedButton<String>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(value: 'podcasts', label: Text(t('Podcasts'))),
            ButtonSegment(value: 'books', label: Text(t('Audiobooks'))),
            ButtonSegment(value: 'music', label: Text(t('Music'))),
          ],
          selected: {_lists.contains(list) ? list : 'podcasts'},
          onSelectionChanged: (s) => _switch(s.first),
        ),
      ),
    );
    final l = entries;
    Widget body;
    if (l == null) {
      body = const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()));
    } else if (l.isEmpty) {
      body = emptyText(context, list == 'music' ? t('Nothing here yet. Add albums with Next.') : t('Nothing to continue.'));
    } else {
      body = ReorderableListView.builder(
        padding: const EdgeInsets.all(12),
        buildDefaultDragHandles: false,
        itemCount: l.length,
        onReorderItem: _reorder,
        itemBuilder: (context, i) {
          final e = l[i], music = list == 'music';
          final base = Item(key: e.key, kind: list == 'podcasts' ? 'episode' : list == 'books' ? 'book' : 'album', title: e.title,
              subtitle: e.subtitle, image: coverOf(e.key), positionMs: e.positionMs, durationMs: e.durationMs);
          final info = e.positionMs > 0
              ? '${clock(e.positionMs)}${e.durationMs != null ? ' / ${clock(e.durationMs!)}' : ''}'
                  '${e.updatedAt == null ? '' : ' · ${e.device.isEmpty ? ago(e.updatedAt!) : t('Last on {device} · {ago}', {'device': remote.shown(e.device), 'ago': ago(e.updatedAt!)})}'}'
              : e.subtitle;
          return KeyedSubtree(
            key: ValueKey(e.key),
            child: ItemRow(
              leading: ReorderableDragStartListener(
                index: i,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.drag_indicator, color: k.muted, semanticLabel: t('Move')),
                  const SizedBox(width: 4),
                  CoverThumb(image: base.image, label: e.subtitle.isEmpty ? e.title : e.subtitle),
                ]),
              ),
              title: e.title.isEmpty ? e.key : e.title,
              subtitle: info,
              progress: e.durationMs != null && e.durationMs! > 0 && e.positionMs > 0 ? e.positionMs / e.durationMs! : null,
              onTap: music ? () => playEntry(context, list, e, widget.onPlay) : () => openDetails(context, base, widget.onPlay),
              trailing: [
                if (!music) ListenableBuilder(listenable: downloads, builder: (context, _) => offlineIcon(context, e.key, showOnlineOnly: true)),
                IconButton(
                  tooltip: music ? t('Remove from the list') : t('Mark as heard'),
                  onPressed: () => _bin(e),
                  icon: const Icon(Icons.delete_outline),
                ),
                playButton(context, e.positionMs > 0 ? t('Resume') : t('Play'), () => playEntry(context, list, e, widget.onPlay)),
              ],
            ),
          );
        },
      );
    }
    return Column(children: [seg, Expanded(child: RefreshIndicator(onRefresh: _load, child: body))]);
  }
}
