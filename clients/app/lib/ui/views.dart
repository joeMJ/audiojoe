// The main screens: now playing, continue, podcasts, audiobooks, music, offline.

import 'package:flutter/material.dart';

import '../api.dart';
import '../downloads.dart';
import '../l10n.dart';
import '../models.dart';
import '../player.dart';
import '../sonos.dart';
import '../store.dart';
import 'common.dart';

Future<void> startPlayback(BuildContext context, List<Item> items, [int i = 0, VoidCallback? opened]) async {
  // A search field may still hold the keyboard; the player view must get the full height.
  FocusManager.instance.primaryFocus?.unfocus();
  try {
    await player.play(items, i);
    opened?.call();
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${t('Error')}: $e')));
  }
}

Widget saveOfflineButton(Item it, [List<Item>? all]) => ListenableBuilder(
      listenable: downloads,
      builder: (context, _) => offlineIcon(context, it.key, onSave: () => downloads.add(all ?? [it])),
    );

// ---------------------------------------------------------------- now playing

class NowPlayingView extends StatelessWidget {
  const NowPlayingView({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([player, sonos]),
        builder: (context, _) {
          final it = player.item;
          if (it == null) return emptyText(context, t('Nothing is playing.'));
          final k = context.tok;
          final wide = MediaQuery.sizeOf(context).width >= 720;
          final pos = player.position, dur = player.duration;
          final suffix = player.fromCache ? t('from cache') : t('unchanged');
          final cover = CoverThumb(image: it.image, label: it.subtitle.isEmpty ? it.title : it.subtitle, size: wide ? 220 : 280);
          final info = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(it.kind == 'episode' ? 'Podcast · ${it.subtitle}' : it.subtitle,
                style: TextStyle(color: k.muted, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(it.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
            if (player.chapter.isNotEmpty) Text(player.chapter, style: TextStyle(fontSize: 16, color: k.muted)),
            const SizedBox(height: 10),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Table(defaultColumnWidth: const IntrinsicColumnWidth(), children: [
                  TableRow(children: [Text(t('Source'), style: TextStyle(color: k.muted)), const SizedBox(width: 10),
                    Text(it.quality?.text ?? '–', style: const TextStyle(fontWeight: FontWeight.w700))]),
                  TableRow(children: [Text(t('Here'), style: TextStyle(color: k.muted)), const SizedBox(width: 10),
                    Text('${it.quality?.text ?? '–'} · $suffix', style: const TextStyle(fontWeight: FontWeight.w700))]),
                ]),
              ),
            ),
            if (player.live)
              Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Badge2(t('Live'), kind: 'ok'))
            else ...[
              Slider(
                value: dur > 0 ? (pos / dur).clamp(0.0, 1.0) : 0,
                onChanged: dur > 0 ? (v) => player.seekTo((v * dur).round()) : null,
              ),
              Row(children: [Text(clock(pos)), const Spacer(), Text(dur > 0 ? '−${clock(dur - pos)}' : '')]),
            ],
            const SizedBox(height: 8),
            Wrap(spacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
              if (player.queue.length > 1) IconButton.outlined(iconSize: 30, onPressed: () => player.skip(-1), icon: const Icon(Icons.skip_previous)),
              if (!player.live) IconButton.outlined(iconSize: 30, onPressed: () => player.seekBy(-30000), icon: const Icon(Icons.replay_30)),
              IconButton.filled(
                  iconSize: 48,
                  onPressed: () => sonos.output != null ? sonos.toggle() : player.toggle(),
                  icon: Icon((sonos.output?.playing ?? player.playing) ? Icons.pause : Icons.play_arrow)),
              if (!player.live) IconButton.outlined(iconSize: 30, onPressed: () => player.seekBy(30000), icon: const Icon(Icons.forward_30)),
              if (player.live)
                const SizedBox.shrink()
              else if (player.queue.length > 1)
                IconButton.outlined(iconSize: 30, onPressed: () => player.skip(1), icon: const Icon(Icons.skip_next))
              else
                OutlinedButton(onPressed: player.nextRate, child: Text('${player.rate}×')),
            ]),
            const SizedBox(height: 8),
            Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              ActionChip(
                avatar: const Icon(Icons.speaker),
                label: Text(sonos.output == null ? t('This device') : 'Sonos ${sonos.output!.name}'),
                onPressed: () => showModalBottomSheet(context: context, builder: (_) => const OutputSheet()),
              ),
              if (sonos.output != null) ...[
                IconButton(onPressed: () => sonos.volume(-3), icon: const Icon(Icons.volume_down)),
                Text('${sonos.output!.volume ?? '?'}'),
                IconButton(onPressed: () => sonos.volume(3), icon: const Icon(Icons.volume_up)),
              ],
            ]),
            if (sonos.output != null)
              Text(t('Playing on {name}', {'name': 'Sonos ${sonos.output!.name}'}), style: TextStyle(color: k.muted))
            else if (player.takenOver != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(t('Taken over from {device} · {ago}', {'device': player.takenOver!.device, 'ago': ago(player.takenOver!.at)}),
                    style: TextStyle(color: k.muted)),
              ),
          ]);
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: wide
                ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [cover, const SizedBox(width: 20), Expanded(child: info)])
                : Column(children: [Center(child: cover), const SizedBox(height: 16), info]),
          );
        },
      );
}

class OutputSheet extends StatelessWidget {
  const OutputSheet({super.key});

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(t('Output'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            ItemRow(
              leading: const Icon(Icons.smartphone, size: 32),
              title: t('This device'),
              subtitle: t('from cache or stream'),
              trailing: [
                FilledButton(
                  onPressed: sonos.output == null ? null : () {
                    Navigator.pop(context);
                    sonos.backToDevice();
                  },
                  child: Text(sonos.output == null ? t('active') : t('Switch here')),
                ),
              ],
            ),
            Flexible(
              child: Loader<List<Room>>(
                load: sonos.rooms,
                builder: (context, rooms, _) => ListView(shrinkWrap: true, children: [
                  for (final r in rooms)
                    ItemRow(
                      leading: const Icon(Icons.speaker, size: 32),
                      title: 'Sonos ${r.name}',
                      subtitle: '${r.model} · ${r.s2 ? t('up to 24 bit / 48 kHz') : t('up to 16 bit / 48 kHz')}',
                      trailing: [
                        Badge2(!r.reachable ? t('switched off') : r.playing ? t('playing') : t('available'),
                            kind: !r.reachable ? 'bad' : r.playing ? 'warn' : 'ok'),
                        FilledButton(
                          // Close the sheet at once; an error shows on the player view below.
                          onPressed: !r.reachable ? null : () async {
                            final messenger = ScaffoldMessenger.of(context);
                            Navigator.pop(context);
                            try {
                              await sonos.playOn(r);
                            } catch (e) {
                              messenger.showSnackBar(SnackBar(content: Text('${t('Error')}: $e')));
                            }
                          },
                          child: Text(t('Play here')),
                        ),
                      ],
                    ),
                ]),
              ),
            ),
          ]),
        ),
      );
}

// ---------------------------------------------------------------- continue

class ContinueView extends StatelessWidget {
  final VoidCallback onPlay;
  const ContinueView({super.key, required this.onPlay});

  Future<List<Playback>> _load() async {
    try {
      final l = await api.call('GET', '/playback', query: {'unfinished': 'true', 'limit': '30'}) as List;
      return l.map((e) => Playback.fromJson((e as Map).cast<String, dynamic>())).toList();
    } catch (_) {
      // Offline: what this device knows.
      return Stores.positions.data.values
          .map((j) => Playback.fromJson(j))
          .where((p) => !p.finished && p.positionMs > 0)
          .toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    }
  }

  @override
  Widget build(BuildContext context) => Loader<List<Playback>>(
        load: _load,
        builder: (context, list, _) {
          if (list.isEmpty) return emptyText(context, t('Nothing to continue.'));
          return ListView(padding: const EdgeInsets.all(12), children: [
            for (final p in list)
              ItemRow(
                leading: CoverThumb(label: p.subtitle.isEmpty ? p.title : p.subtitle),
                title: p.title.isEmpty ? p.key : p.title,
                subtitle: '${clock(p.positionMs)}${p.durationMs != null ? ' / ${clock(p.durationMs!)}' : ''} · '
                    '${p.device.isEmpty ? ago(p.updatedAt) : t('Last on {device} · {ago}', {'device': p.device, 'ago': ago(p.updatedAt)})}',
                progress: p.durationMs != null && p.durationMs! > 0 ? p.positionMs / p.durationMs! : null,
                trailing: [
                  ListenableBuilder(listenable: downloads, builder: (context, _) => offlineIcon(context, p.key, showOnlineOnly: true)),
                  rowButton(t('Resume'), () => startPlayback(context, [
                        Item(key: p.key, kind: p.key.startsWith('episode:') ? 'episode' : p.key.startsWith('abs:') ? 'book' : 'track',
                            title: p.title, subtitle: p.subtitle)
                      ], 0, onPlay)),
                ],
              ),
          ]);
        },
      );
}

// ---------------------------------------------------------------- podcasts

class PodcastsView extends StatefulWidget {
  final VoidCallback onPlay;
  const PodcastsView({super.key, required this.onPlay});
  @override
  State<PodcastsView> createState() => _PodcastsViewState();
}

class _PodcastsViewState extends State<PodcastsView> {
  bool subscribed = false;
  Map<String, dynamic>? podcast;

  @override
  Widget build(BuildContext context) {
    final chips = Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Wrap(spacing: 8, children: [
        ChoiceChip(label: Text(t('New')), selected: !subscribed && podcast == null, onSelected: (_) => setState(() => (subscribed = false, podcast = null))),
        ChoiceChip(label: Text(t('Subscribed')), selected: subscribed || podcast != null, onSelected: (_) => setState(() => (subscribed = true, podcast = null))),
        if (podcast != null) ActionChip(label: Text('← ${t('Back')}'), onPressed: () => setState(() => podcast = null)),
        ActionChip(avatar: const Icon(Icons.add), label: Text(t('Add podcast')), onPressed: () async {
          if (await showDialog<bool>(context: context, builder: (_) => const AddPodcastDialog()) == true) {
            setState(() => (subscribed = true, podcast = null));
          }
        }),
      ]),
    );
    Widget body;
    if (subscribed && podcast == null) {
      body = Loader<List>(
        key: const ValueKey('subs'),
        load: () async => await api.call('GET', '/podcasts') as List,
        builder: (context, pods, reload) => pods.isEmpty
            ? emptyText(context, t('No podcasts subscribed yet.'))
            : ListView(padding: const EdgeInsets.all(12), children: [
                for (final p in pods.cast<Map>())
                  ItemRow(
                    leading: CoverThumb(image: null, label: p['title'] as String),
                    title: p['title'] as String,
                    subtitle: '${p['author']} · ${p['episodes']}',
                    onTap: () => setState(() => podcast = p.cast<String, dynamic>()),
                    trailing: [
                      IconButton(
                        tooltip: t('Unsubscribe'),
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          await api.call('DELETE', '/podcasts/${p['id']}');
                          reload();
                        },
                      ),
                    ],
                  ),
              ]),
      );
    } else {
      body = Loader<List<Item>>(
        key: ValueKey(podcast?['id'] ?? 'new'),
        load: () async => itemsOf(podcast == null
            ? await api.call('GET', '/episodes/latest', query: {'limit': '40'})
            : await api.call('GET', '/podcasts/${podcast!['id']}/episodes', query: {'limit': '100'})),
        builder: (context, eps, _) => ListView(padding: const EdgeInsets.all(12), children: [
          for (final e in eps.map((e) => Item(key: e.key, kind: 'episode', title: e.title, subtitle: e.subtitle, durationMs: e.durationMs,
              published: e.published, positionMs: e.positionMs, finished: e.finished)))
            ItemRow(
              leading: CoverThumb(label: e.subtitle),
              title: e.title,
              subtitle: [e.subtitle, e.published?.substring(0, 10), if (e.durationMs != null) clock(e.durationMs!)].whereType<String>().join(' · '),
              progress: e.positionMs != null && e.durationMs != null && !e.finished ? e.positionMs! / e.durationMs! : null,
              trailing: [
                saveOfflineButton(e),
                rowButton((e.positionMs ?? 0) > 0 ? t('Resume') : t('Play'), () => startPlayback(context, [e], 0, widget.onPlay)),
              ],
            ),
        ]),
      );
    }
    return Column(children: [chips, Expanded(child: body)]);
  }
}

class AddPodcastDialog extends StatefulWidget {
  const AddPodcastDialog({super.key});
  @override
  State<AddPodcastDialog> createState() => _AddPodcastDialogState();
}

class _AddPodcastDialogState extends State<AddPodcastDialog> {
  final q = TextEditingController();
  List results = [];
  String error = '';
  bool busy = false;

  Future<void> _subscribe(String url) async {
    setState(() => busy = true);
    try {
      await api.call('POST', '/podcasts', body: {'feed_url': url});
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() => (error = '$e', busy = false));
    }
  }

  Future<void> _search() async {
    final s = q.text.trim();
    if (s.startsWith('http')) return _subscribe(s);
    setState(() => (busy = true, error = ''));
    try {
      results = await api.call('GET', '/podcasts/search', query: {'q': s}) as List;
    } catch (e) {
      error = '$e';
    }
    setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(t('Add podcast')),
        content: SizedBox(
          width: 520,
          height: 420,
          child: Column(children: [
            TextField(controller: q, autofocus: true, onSubmitted: (_) => _search(),
                decoration: InputDecoration(labelText: t('Search or feed URL'), suffixIcon: IconButton(icon: const Icon(Icons.search), onPressed: _search))),
            if (busy) const LinearProgressIndicator(),
            if (error.isNotEmpty) Text(error, style: TextStyle(color: context.tok.bad)),
            Expanded(
              child: ListView(children: [
                for (final r in results.cast<Map>())
                  ListTile(
                    title: Text('${r['title']}'),
                    subtitle: Text('${r['author'] ?? ''}', maxLines: 1),
                    trailing: TextButton(onPressed: busy ? null : () => _subscribe(r['feed_url'] as String), child: Text(t('Subscribe'))),
                  ),
              ]),
            ),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t('Cancel')))],
      );
}

// ---------------------------------------------------------------- audiobooks and music (browse a source)

class BrowseView extends StatefulWidget {
  final List<String> kinds; // [audiobookshelf] or [jellyfin, emby, plex]
  final VoidCallback onPlay;
  const BrowseView({super.key, required this.kinds, required this.onPlay});
  @override
  State<BrowseView> createState() => _BrowseViewState();
}

class _BrowseViewState extends State<BrowseView> {
  final stack = <({int source, String? parent, String title})>[];

  Future<List<Item>> _load() async {
    if (stack.isEmpty) {
      final sources = (await api.call('GET', '/sources') as List).cast<Map>().where((s) => widget.kinds.contains(s['kind'])).toList();
      if (sources.isEmpty) return [];
      stack.add((source: sources.first['id'] as int, parent: null, title: sources.first['name'] as String));
    }
    final cur = stack.last;
    final res = await api.call('GET', '/sources/${cur.source}/browse',
        query: {if (cur.parent != null) 'parent': cur.parent!, 'limit': '500'});
    final items = itemsOf(res['items']);
    // A single library: show its content directly.
    if (cur.parent == null && items.length == 1 && items.first.kind == 'folder') {
      stack.add((source: cur.source, parent: items.first.key.split(':')[2], title: items.first.title));
      return _load();
    }
    return items;
  }

  @override
  Widget build(BuildContext context) => Loader<List<Item>>(
        key: ValueKey(stack.isEmpty ? 'root' : '${stack.last.source}/${stack.last.parent}'),
        load: _load,
        builder: (context, items, _) {
          if (stack.isEmpty) return emptyText(context, t('No sources yet. Add one in the settings.'));
          final tracks = items.where((i) => i.kind == 'track').toList();
          final positions = Stores.positions.data;
          return ListView(padding: const EdgeInsets.all(12), children: [
            Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              if (stack.length > 1) ActionChip(label: Text('← ${t('Back')}'), onPressed: () => setState(stack.removeLast)),
              Text(stack.last.title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              if (tracks.isNotEmpty) ...[
                FilledButton(onPressed: () => startPlayback(context, tracks, 0, widget.onPlay), child: Text(t('Play all'))),
                saveOfflineButton(tracks.first, tracks),
              ],
            ]),
            const SizedBox(height: 10),
            for (final it in items)
              if (it.kind == 'folder' || it.kind == 'album' || it.kind == 'artist')
                ItemRow(
                  leading: CoverThumb(image: it.image, label: it.title),
                  title: it.title,
                  subtitle: [it.subtitle, if (it.year != null) '${it.year}'].where((s) => s.isNotEmpty).join(' · '),
                  onTap: () => setState(() => stack.add((source: stack.last.source, parent: it.key.split(':')[2], title: it.title))),
                )
              else
                ItemRow(
                  leading: it.kind == 'track' ? CoverThumb(label: '${it.track ?? ''}') : CoverThumb(image: it.image, label: it.title),
                  title: it.title,
                  subtitle: [it.subtitle, if (it.durationMs != null) clock(it.durationMs!)].where((s) => s.isNotEmpty).join(' · '),
                  progress: () {
                    final p = positions[it.key];
                    return p != null && it.durationMs != null && p['finished'] != true ? (p['position_ms'] as int) / it.durationMs! : null;
                  }(),
                  onTap: it.kind == 'track' ? () => startPlayback(context, tracks, tracks.indexOf(it), widget.onPlay) : null,
                  trailing: [
                    if (it.quality?.badge.isNotEmpty == true) Badge2(it.quality!.badge),
                    saveOfflineButton(it),
                    if (it.kind == 'book') rowButton(t('Play'), () => startPlayback(context, [it], 0, widget.onPlay)),
                  ],
                ),
          ]);
        },
      );
}

// ---------------------------------------------------------------- music: library or internet radio

class MusicTab extends StatefulWidget {
  final VoidCallback onPlay;
  const MusicTab({super.key, required this.onPlay});
  @override
  State<MusicTab> createState() => _MusicTabState();
}

class _MusicTabState extends State<MusicTab> {
  bool radio = false;

  @override
  Widget build(BuildContext context) => Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: SegmentedButton<bool>(
            segments: [ButtonSegment(value: false, label: Text(t('Library'))), ButtonSegment(value: true, label: Text(t('Internet radio')))],
            selected: {radio},
            onSelectionChanged: (s) => setState(() => radio = s.first),
          ),
        ),
        Expanded(child: radio ? RadioView(onPlay: widget.onPlay) : BrowseView(key: const ValueKey('jf'), kinds: const ['jellyfin', 'emby', 'plex'], onPlay: widget.onPlay)),
      ]);
}

class RadioView extends StatefulWidget {
  final VoidCallback onPlay;
  const RadioView({super.key, required this.onPlay});
  @override
  State<RadioView> createState() => _RadioViewState();
}

class _RadioViewState extends State<RadioView> {
  final q = TextEditingController();
  String query = '';

  @override
  Widget build(BuildContext context) => Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: q,
            textInputAction: TextInputAction.search,
            onSubmitted: (v) => setState(() => query = v.trim()),
            decoration: InputDecoration(
              labelText: t('Search stations'),
              suffixIcon: query.isEmpty
                  ? IconButton(icon: const Icon(Icons.search), onPressed: () => setState(() => query = q.text.trim()))
                  : IconButton(icon: const Icon(Icons.close), onPressed: () { q.clear(); setState(() => query = ''); }),
            ),
          ),
        ),
        Expanded(
          child: Loader<List<Item>>(
            key: ValueKey(query),
            load: () async => itemsOf(query.isEmpty
                ? await api.call('GET', '/radio/favorites')
                : await api.call('GET', '/radio/search', query: {'q': query})),
            builder: (context, list, reload) => list.isEmpty
                ? emptyText(context, query.isEmpty ? t('No favourites yet. Search for a station.') : t('No stations found.'))
                : ListView(padding: const EdgeInsets.symmetric(horizontal: 12), children: [
                    for (final st in list)
                      ItemRow(
                        leading: CoverThumb(image: st.image, label: st.title),
                        title: st.title,
                        subtitle: st.subtitle,
                        onTap: () => startPlayback(context, [st], 0, widget.onPlay),
                        trailing: [
                          if (st.quality?.badge.isNotEmpty == true) Badge2(st.quality!.badge),
                          IconButton(
                            tooltip: t('Favourite'),
                            icon: Icon(st.favorite ? Icons.star : Icons.star_border),
                            onPressed: () async {
                              await api.call(st.favorite ? 'DELETE' : 'PUT', '/radio/favorites/${st.key.substring(6)}');
                              reload();
                            },
                          ),
                        ],
                      ),
                  ]),
          ),
        ),
      ]);
}

// ---------------------------------------------------------------- offline

class OfflineView extends StatelessWidget {
  const OfflineView({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: downloads,
        builder: (context, _) {
          final list = downloads.entries;
          final used = list.where((e) => e.status == 'done').fold<int>(0, (s, e) => s + e.bytes);
          return ListView(padding: const EdgeInsets.all(12), children: [
            Text(t('Used {used}', {'used': bytes(used)}), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            if (list.isEmpty) emptyText(context, t('Nothing saved offline yet.')),
            for (final e in list)
              ItemRow(
                leading: CoverThumb(label: e.title),
                title: e.title,
                subtitle: [e.subtitle, if (e.bytes > 0) bytes(e.bytes), e.quality?.badge ?? ''].where((s) => s.isNotEmpty).join(' · '),
                progress: e.status == 'loading' ? e.progress : null,
                trailing: [
                  Badge2(
                    switch (e.status) {
                      'done' => t('ready'),
                      'error' => t('failed'),
                      'missing' => t('missing – will reload'),
                      'loading' => t('loading {p}', {'p': '${(e.progress * 100).round()} %'}),
                      _ => t('waiting'),
                    },
                    kind: e.status == 'done' ? 'ok' : e.status == 'error' ? 'bad' : 'warn',
                  ),
                  if (e.status == 'error') IconButton(onPressed: downloads.retry, icon: const Icon(Icons.refresh)),
                  IconButton(tooltip: t('Remove'), onPressed: () => downloads.remove(e.key), icon: const Icon(Icons.delete_outline)),
                ],
              ),
          ]);
        },
      );
}
