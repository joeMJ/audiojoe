// Music: albums, artists, samplers, genres, years, new arrivals (and labels, once enough albums
// have one) of all visible music libraries, from the server's album directory, with a search
// over title, artist, genre, label and year. The chosen view is kept per device.

import 'package:flutter/material.dart';

import '../api.dart';
import '../l10n.dart';
import '../models.dart';
import '../store.dart';
import 'common.dart';
import 'details.dart';
import 'lists.dart';
import 'views.dart';

class Album {
  final Item item;
  final int source;
  final String artist;
  final bool sampler;
  final List<String> genres;
  final String? added, label;
  final int? tracks;
  Album(this.source, Map<String, dynamic> j)
      : item = Item.fromJson(j),
        artist = (j['artist'] ?? '') as String,
        sampler = (j['sampler'] ?? false) as bool,
        genres = [for (final g in (j['genres'] as List? ?? const [])) '$g'],
        added = j['added'] as String?,
        label = j['label'] as String?,
        tracks = j['tracks'] as int?;
}

class Collection {
  final List<Album> albums;
  final bool labels;
  Collection(this.albums, this.labels);
}

/// "The Beatles" sorts under B.
String sortName(String s) {
  final l = s.trim().toLowerCase();
  return l.startsWith('the ') ? l.substring(4) : l;
}

String albumCount(int n) => n == 1 ? t('1 album') : t('{n} albums', {'n': n});

int byTitle(Album a, Album b) => a.item.title.toLowerCase().compareTo(b.item.title.toLowerCase());
int byArtist(Album a, Album b) {
  final c = sortName(a.artist).compareTo(sortName(b.artist));
  return c != 0 ? c : (a.item.year ?? 0).compareTo(b.item.year ?? 0);
}

class MusicView extends StatefulWidget {
  final VoidCallback onPlay;
  const MusicView({super.key, required this.onPlay});
  @override
  State<MusicView> createState() => _MusicViewState();
}

class _MusicViewState extends State<MusicView> {
  String view = (Stores.device.get('music')?['view'] as String?) ?? 'albums';
  String query = '';
  ({String title, String sub, List<Album> albums})? group; // an opened artist, genre, year or label
  Album? album; // an opened album
  final search = TextEditingController();
  final scroll = ScrollController();

  Future<Collection> _load() async {
    final out = <Album>[];
    var labels = 0;
    final sources = (await api.call('GET', '/sources') as List).cast<Map>().where((s) => ['jellyfin', 'emby', 'plex'].contains(s['kind']));
    if (sources.isEmpty) throw t('No sources yet. Add one in the settings.');
    Object? failed;
    for (final s in sources) {
      final src = s['id'] as int;
      // A source that is down leaves out its albums, not everyone else's.
      try {
        final libs = itemsOf((await api.call('GET', '/sources/$src/browse'))['items']);
        for (final l in libs.where((l) => l.kind == 'folder')) {
          final res = await api.call('GET', '/sources/$src/music', query: {'parent': l.key.split(':')[2]}) as Map;
          out.addAll([for (final a in res['albums'] as List) Album(src, (a as Map).cast<String, dynamic>())]);
          if (res['labels'] == true) labels++;
        }
      } catch (e) {
        failed = e;
      }
    }
    if (out.isEmpty && failed != null) throw failed;
    final withLabel = out.where((a) => a.label != null).length;
    return Collection(out, labels > 0 || (out.isNotEmpty && withLabel >= out.length * 0.1));
  }

  void _setView(String v) => setState(() {
        view = v;
        group = null;
        album = null;
        Stores.device.put('music', {'view': v});
      });

  @override
  void dispose() {
    search.dispose();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Loader<Collection>(
        load: _load,
        builder: (context, col, _) {
          final views = [
            ('albums', t('Albums')),
            ('artists', t('Artists')),
            ('samplers', t('Samplers')),
            ('genres', t('Genres')),
            ('years', t('Years')),
            ('new', t('Recently added')),
            if (col.labels) ('labels', t('Labels')),
          ];
          final current = views.any((v) => v.$1 == view) ? view : 'albums';
          // The list stays underneath an opened album, so "Back" returns to the same place.
          final list = ListView(controller: scroll, padding: const EdgeInsets.all(12), children: [
            TextField(
              controller: search,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: t('Search title, artist, genre, label'),
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(icon: const Icon(Icons.clear), tooltip: t('Clear'), onPressed: () => setState(() {
                          search.clear();
                          query = '';
                        })),
              ),
              onChanged: (s) => setState(() => query = s.trim().toLowerCase()),
            ),
            const SizedBox(height: 10),
            if (query.isEmpty) ...[
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final v in views)
                  ChoiceChip(
                    label: Text(v.$2),
                    showCheckmark: false,
                    selected: group == null && current == v.$1,
                    onSelected: (_) => _setView(v.$1),
                  ),
              ]),
              const SizedBox(height: 10),
            ],
            ..._content(context, col, current),
          ]);
          // The system back gesture closes the album, then the artist (genre, year, label).
          return PopScope(
            canPop: album == null && group == null,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) setState(() => album != null ? album = null : group = null);
            },
            child: Stack(children: [
            Offstage(offstage: album != null, child: list),
            if (album != null)
              AlbumPage(
                key: ValueKey(album!.item.key),
                source: album!.source,
                album: album!.item,
                onPlay: widget.onPlay,
                onBack: () => setState(() => album = null),
              ),
          ]));
        },
      );

  List<Widget> _content(BuildContext context, Collection col, String view) {
    final all = col.albums;
    if (query.isNotEmpty) {
      final hits = all
          .where((a) => [a.item.title, a.artist, a.label ?? '', '${a.item.year ?? ''}', ...a.genres].any((s) => s.toLowerCase().contains(query)))
          .toList()
        ..sort(byArtist);
      return hits.isEmpty ? [emptyText(context, t('Nothing found.'))] : [for (final a in hits.take(300)) _album(context, a)];
    }
    if (group != null) {
      return [
        _head(context, group!.title, group!.sub, () => setState(() => group = null)),
        for (final a in group!.albums) _album(context, a),
      ];
    }
    Widget folder(String title, List<Album> albums, {required List<Album> Function() sorted}) => ItemRow(
          leading: CoverThumb(image: albums.firstWhere((a) => a.item.image != null, orElse: () => albums.first).item.image, label: title),
          title: title,
          subtitle: albumCount(albums.length),
          onTap: () => setState(() => group = (title: title, sub: albumCount(albums.length), albums: sorted())),
        );
    Map<String, List<Album>> groupBy(Iterable<Album> l, Iterable<String> Function(Album) keys) {
      final m = <String, List<Album>>{};
      for (final a in l) {
        for (final k in keys(a)) {
          if (k.trim().isNotEmpty) m.putIfAbsent(k.trim(), () => []).add(a);
        }
      }
      return m;
    }

    switch (view) {
      case 'artists':
        final m = groupBy(all.where((a) => !a.sampler), (a) => [a.artist]);
        final names = m.keys.toList()..sort((a, b) => sortName(a).compareTo(sortName(b)));
        // An artist's albums by year, the oldest first.
        return [
          for (final n in names)
            folder(n, m[n]!, sorted: () => [...m[n]!]..sort((a, b) => (a.item.year ?? 9999).compareTo(b.item.year ?? 9999))),
        ];
      case 'samplers':
        return [for (final a in all.where((a) => a.sampler).toList()..sort(byTitle)) _album(context, a)];
      case 'genres':
        final m = groupBy(all, (a) => a.genres);
        final names = m.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        return [for (final n in names) folder(n, m[n]!, sorted: () => [...m[n]!]..sort(byArtist))];
      case 'years':
        final m = groupBy(all, (a) => [if (a.item.year != null) '${a.item.year}']);
        final years = m.keys.toList()..sort((a, b) => b.compareTo(a));
        return [for (final y in years) folder(y, m[y]!, sorted: () => [...m[y]!]..sort(byArtist))];
      case 'labels':
        final m = groupBy(all, (a) => [a.label ?? '']);
        final names = m.keys.toList()..sort((a, b) => sortName(a).compareTo(sortName(b)));
        return [for (final n in names) folder(n, m[n]!, sorted: () => [...m[n]!]..sort(byArtist))];
      case 'new':
        final l = [...all]..sort((a, b) => (b.added ?? '').compareTo(a.added ?? ''));
        return [for (final a in l.take(100)) _album(context, a)];
      default:
        return [for (final a in [...all]..sort(byTitle)) _album(context, a)];
    }
  }

  Widget _head(BuildContext context, String title, String sub, VoidCallback back) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Wrap(spacing: 10, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          ActionChip(label: Text('← ${t('Back')}'), onPressed: back),
          Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          Text(sub, style: TextStyle(color: context.tok.muted)),
        ]),
      );

  Widget _album(BuildContext context, Album a) => ItemRow(
        leading: CoverThumb(image: a.item.image, label: a.item.title),
        title: a.item.title,
        subtitle: [
          a.artist,
          if (a.item.year != null) '${a.item.year}',
          if (a.tracks != null) t('{n} titles', {'n': a.tracks!}),
        ].where((s) => s.isNotEmpty).join(' · '),
        trailing: [NextButton(a.item)],
        onTap: () => setState(() => album = a),
      );
}

/// One album: cover and facts, "Play album", the titles (a tap plays, a long press shows details).
class AlbumPage extends StatelessWidget {
  final int source;
  final Item album;
  final VoidCallback onPlay, onBack;
  const AlbumPage({super.key, required this.source, required this.album, required this.onPlay, required this.onBack});

  @override
  Widget build(BuildContext context) => Loader<List<Item>>(
        load: () async => itemsOf((await api.call('GET', '/sources/$source/browse', query: {'parent': album.key.split(':')[2], 'limit': '500'}))['items'])
            .where((i) => i.kind == 'track')
            .toList(),
        builder: (context, tracks, _) {
          final positions = Stores.positions.data;
          return ListView(padding: const EdgeInsets.all(12), children: [
            Align(alignment: Alignment.centerLeft, child: ActionChip(label: Text('← ${t('Back')}'), onPressed: onBack)),
            const SizedBox(height: 10),
            AlbumHeader(album: album, tracks: tracks, actions: [
              if (tracks.isNotEmpty) ...[
                FilledButton.icon(
                    icon: const Icon(Icons.play_arrow),
                    onPressed: () => startPlayback(context, tracks, 0, onPlay, (list: 'music', key: album.key)),
                    label: Text(t('Play album'))),
                saveOfflineButton(tracks.first, tracks),
                NextButton(album),
              ],
            ]),
            const SizedBox(height: 10),
            for (final it in tracks)
              ItemRow(
                leading: CoverThumb(label: '${it.track ?? ''}'),
                title: it.title,
                subtitle: [it.subtitle, if (it.durationMs != null) clock(it.durationMs!)].where((s) => s.isNotEmpty).join(' · '),
                progress: () {
                  final p = positions[it.key];
                  return p != null && it.durationMs != null && p['finished'] != true ? (p['position_ms'] as int) / it.durationMs! : null;
                }(),
                onTap: () => startPlayback(context, tracks, tracks.indexOf(it), onPlay),
                onLongPress: () => openDetails(context, it, onPlay),
                // No single titles offline (user 2026-11-04): the album button saves the album.
                trailing: [
                  if (it.quality?.badge.isNotEmpty == true) Badge2(it.quality!.badge),
                ],
              ),
          ]);
        },
      );
}
