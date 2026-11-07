// The main screens: continue, podcasts, audiobooks, music, downloads.

import 'package:flutter/material.dart';

import '../api.dart';
import '../downloads.dart';
import '../l10n.dart';
import '../models.dart';
import '../player.dart';
import '../storage.dart';
import '../store.dart';
import 'common.dart';
import 'details.dart';
import 'lists.dart';
import 'music.dart';

Future<void> startPlayback(BuildContext context, List<Item> items, [int i = 0, VoidCallback? opened, Entry? from]) async {
  // A search field may still hold the keyboard; the player view must get the full height.
  FocusManager.instance.primaryFocus?.unfocus();
  try {
    await player.play(items, i, from);
    opened?.call();
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${t('Error')}: $e')));
  }
}

Widget saveOfflineButton(Item it, [List<Item>? all, Item? album]) => ListenableBuilder(
      listenable: downloads,
      builder: (context, _) => offlineIcon(context, it.key, onSave: () => downloads.add(all ?? [it], album: album)),
    );

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
                    leading: CoverThumb(image: p['image'] as String?, label: p['title'] as String),
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
          if (podcast != null) PodcastHeader(podcast!),
          for (final e in eps.map((e) => Item(key: e.key, kind: 'episode', title: e.title, subtitle: e.subtitle, durationMs: e.durationMs,
              published: e.published, positionMs: e.positionMs, finished: e.finished, image: e.image, description: e.description)))
            ItemRow(
              leading: CoverThumb(image: e.image, label: e.subtitle),
              onTap: () => openDetails(context, e, widget.onPlay),
              title: e.title,
              subtitle: [e.subtitle, e.published?.substring(0, 10), if (e.durationMs != null) clock(e.durationMs!)].whereType<String>().join(' · '),
              progress: e.positionMs != null && e.durationMs != null && !e.finished ? e.positionMs! / e.durationMs! : null,
              trailing: [
                saveOfflineButton(e),
                NextButton(e),
                playButton(context, (e.positionMs ?? 0) > 0 ? t('Resume') : t('Play'), () => startPlayback(context, [e], 0, widget.onPlay)),
              ],
            ),
        ]),
      );
    }
    return Column(children: [chips, Expanded(child: body)]);
  }
}

/// Cover, author and description of a subscribed podcast above its episodes.
class PodcastHeader extends StatefulWidget {
  final Map<String, dynamic> podcast;
  const PodcastHeader(this.podcast, {super.key});
  @override
  State<PodcastHeader> createState() => _PodcastHeaderState();
}

class _PodcastHeaderState extends State<PodcastHeader> {
  bool open = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.podcast, k = context.tok;
    final desc = (p['description'] ?? '') as String;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        CoverThumb(image: p['image'] as String?, label: '${p['title']}', size: 96),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${p['title']}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            if ('${p['author'] ?? ''}'.isNotEmpty) Text('${p['author']}', style: TextStyle(color: k.muted, fontWeight: FontWeight.w600)),
            if (desc.isNotEmpty)
              InkWell(
                onTap: () => setState(() => open = !open),
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(desc, maxLines: open ? null : 3, overflow: open ? null : TextOverflow.ellipsis, style: const TextStyle(height: 1.4)),
                ),
              ),
          ]),
        ),
      ]),
    );
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

// ---------------------------------------------------------------- music: library or internet radio

class MusicTab extends StatefulWidget {
  final VoidCallback onPlay;
  const MusicTab({super.key, required this.onPlay});
  @override
  State<MusicTab> createState() => _MusicTabState();
}

class _MusicTabState extends State<MusicTab> {
  @override
  Widget build(BuildContext context) => MusicView(onPlay: widget.onPlay);
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
            builder: (context, list, reload) {
              if (list.isEmpty) {
                return emptyText(context, query.isEmpty ? t('No favourites yet. Search for a station.') : t('No stations found.'));
              }
              Widget row(Item st, {Widget? handle}) => ItemRow(
                    leading: handle == null
                        ? CoverThumb(image: st.image, label: st.title)
                        : Row(mainAxisSize: MainAxisSize.min, children: [handle, const SizedBox(width: 4), CoverThumb(image: st.image, label: st.title)]),
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
                  );
              if (query.isNotEmpty) {
                return ListView(padding: const EdgeInsets.symmetric(horizontal: 12), children: [for (final st in list) row(st)]);
              }
              // Favourites in the user's order, moved with the handle; the order applies on all devices.
              return ReorderableListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                buildDefaultDragHandles: false,
                itemCount: list.length,
                onReorderItem: (from, to) async {
                  list.insert(to, list.removeAt(from));
                  setState(() {});
                  try {
                    await api.call('PUT', '/radio/favorites', body: [for (final st in list) st.key.substring(6)]);
                  } catch (_) {
                    reload();
                  }
                },
                itemBuilder: (context, i) => KeyedSubtree(
                  key: ValueKey(list[i].key),
                  child: row(list[i],
                      handle: ReorderableDragStartListener(index: i, child: Icon(Icons.drag_indicator, color: context.tok.muted, semanticLabel: t('Move')))),
                ),
              );
            },
          ),
        ),
      ]);
}

// ---------------------------------------------------------------- downloads

/// "Downloads" (0.2.0, mockup android-einstellungen pictures 4 and 5): replaces the offline list.
/// Sections loading, waiting, partly loaded and done, a filter by kind; an album and an audiobook
/// are one line and are deleted whole, a started album loads the rest.
class DownloadsView extends StatefulWidget {
  const DownloadsView({super.key});
  @override
  State<DownloadsView> createState() => _DownloadsViewState();
}

class _DownloadsViewState extends State<DownloadsView> {
  String filter = 'all';

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([downloads, storage]),
        builder: (context, _) {
          final k = context.tok;
          final all = downloads.groups;
          final groups = filter == 'all' ? all : all.where((g) => g.kind == filter).toList();
          final used = all.fold<int>(0, (s, g) => s + g.bytes);
          final n = storage.keepFreeGb;
          final head = [
            t('{used} used', {'used': bytes(used)}),
            if (storage.free != null) t('{free} free', {'free': bytes(storage.free!)}),
            t('keep at least {n} GB free', {'n': n}),
          ].join(' · ');
          List<DownloadGroup> of(String section) => groups.where((g) => g.section == section).toList();
          final loading = of('loading'), waiting = of('waiting'), partial = of('partial'), done = of('done');
          return ListView(key: const ValueKey('downloads'), padding: const EdgeInsets.all(12), children: [
            Text(head, key: const ValueKey('downloads-head'), style: TextStyle(fontSize: 14, color: k.muted)),
            if (storage.low)
              Container(
                key: const ValueKey('downloads-low'),
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: k.warnBg, borderRadius: BorderRadius.circular(10)),
                child: Text(t('Less than {n} GB free: new downloads wait. Delete finished ones or lower the limit under "Storage".', {'n': n}),
                    style: TextStyle(color: k.warn, fontWeight: FontWeight.w600)),
              ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 6, children: [
              for (final (id, label) in [('all', t('All')), ('episode', t('Podcasts')), ('book', t('Audiobooks')), ('track', t('Music'))])
                ChoiceChip(key: ValueKey('downloads-filter-$id'), label: Text(label), selected: filter == id, onSelected: (_) => setState(() => filter = id)),
            ]),
            const SizedBox(height: 6),
            if (groups.isEmpty) emptyText(context, t('Nothing saved offline yet.')),
            if (loading.isNotEmpty) ...[
              _section(context, t('Loading ({n} of at most {max})', {'n': downloads.running, 'max': parallelDownloads})),
              for (final g in loading) _row(context, g),
            ],
            if (waiting.isNotEmpty) ...[
              _section(context, t('Waiting ({n})', {'n': waiting.length})),
              for (final g in waiting) _row(context, g),
            ],
            if (partial.isNotEmpty) ...[
              _section(context, t('Partly loaded ({n})', {'n': partial.length})),
              for (final g in partial) _row(context, g),
            ],
            if (done.isNotEmpty) ...[
              _section(context, t('Done')),
              for (final g in done) _row(context, g),
            ],
          ]);
        },
      );

  Widget _section(BuildContext context, String s) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 14, 4, 4),
        child: Text(s.toUpperCase(), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, letterSpacing: 0.6, color: context.tok.muted)),
      );

  static String _kindLabel(DownloadGroup g) => switch (g.kind) {
        'episode' => t('Podcast'),
        'book' => t('Audiobook'),
        _ => g.isAlbum ? t('Album') : t('Music'),
      };

  Widget _row(BuildContext context, DownloadGroup g) {
    final section = g.section;
    final first = g.entries.first;
    final error = g.entries.map((e) => e.error).whereType<String>().where((s) => s.isNotEmpty).firstOrNull;
    final played = section == 'done' && g.entries.length == 1 && storage.deleteAfter(g.kind) && Stores.positions.get(first.key)?['finished'] == true;
    final details = <String>[
      _kindLabel(g),
      if (g.isAlbum && section != 'done') t('{n} of {total} titles', {'n': g.doneCount, 'total': g.total ?? g.entries.length}),
      if (section == 'waiting') storage.low ? t('waiting for space') : t('waiting'),
      if (section == 'partial' && error != null) error,
      if (g.bytes > 0) bytes(g.bytes),
      if (played) t('played, will be deleted'),
    ];
    final badge = switch (section) {
      'loading' => Badge2('${(g.progress * 100).round()} %', kind: 'warn'),
      'waiting' => Badge2(t('waiting'), kind: 'warn'),
      'partial' => null,
      _ => Badge2(t('done'), kind: 'ok'),
    };
    final open = section == 'loading' || section == 'waiting';
    return ItemRow(
      key: ValueKey('download-${g.id}'),
      leading: CoverThumb(image: coverOf(first.key), label: g.title),
      title: g.title,
      subtitle: details.join(' · '),
      progress: section == 'loading' || section == 'partial' ? g.progress : null,
      trailing: [
        ?badge,
        if (section == 'partial')
          FilledButton(key: ValueKey('load-rest-${g.id}'), onPressed: () => downloads.loadRest(g), child: Text(t('Load rest'))),
        IconButton(
          key: ValueKey('download-delete-${g.id}'),
          tooltip: open ? t('Cancel') : t('Delete'),
          onPressed: () => downloads.removeGroup(g),
          icon: Icon(open ? Icons.close : Icons.backspace_outlined),
        ),
      ],
    );
  }
}
