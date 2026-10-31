// Audiobooks: authors, series, titles and new arrivals of one library, with a search over
// title, author, series and narrator. The chosen view is kept per device.

import 'package:flutter/material.dart';

import '../api.dart';
import '../l10n.dart';
import '../models.dart';
import '../store.dart';
import 'common.dart';
import 'details.dart';
import 'views.dart';

class Book {
  final Item item;
  final String author, narrator, series;
  final int? volume, added;
  Book(Map<String, dynamic> j)
      : item = Item.fromJson(j),
        author = (j['author'] ?? '') as String,
        narrator = (j['narrator'] ?? '') as String,
        series = (j['series'] ?? '') as String,
        volume = j['volume'] as int?,
        added = j['added'] as int?;
}

class Series {
  final String name, author;
  final int total, heard;
  final String? next, image;
  final List<String> books;
  Series(Map<String, dynamic> j)
      : name = j['name'] as String,
        author = (j['author'] ?? '') as String,
        total = j['total'] as int,
        heard = j['heard'] as int,
        next = j['next'] as String?,
        image = j['image'] as String?,
        books = (j['books'] as List).cast<String>();
}

class Shelf {
  final List<Book> books;
  final List<({String name, int books})> authors;
  final List<Series> series;
  final Map<String, Book> byKey;
  Shelf(Map j)
      : books = [for (final b in j['books'] as List) Book((b as Map).cast<String, dynamic>())],
        authors = [for (final a in j['authors'] as List) (name: a['name'] as String, books: a['books'] as int)],
        series = [for (final s in j['series'] as List) Series((s as Map).cast<String, dynamic>())],
        byKey = {} {
    for (final b in books) {
      byKey[b.item.key] = b;
    }
  }
}

const _views = ['authors', 'series', 'titles', 'new'];

class BooksView extends StatefulWidget {
  final VoidCallback onPlay;
  const BooksView({super.key, required this.onPlay});
  @override
  State<BooksView> createState() => _BooksViewState();
}

class _BooksViewState extends State<BooksView> {
  List<({int source, String lib, String title})>? libs;
  int current = 0;
  String view = (Stores.device.get('books')?['view'] as String?) ?? 'authors';
  String query = '';
  String? author; // an opened author
  Series? series; // an opened series
  final search = TextEditingController();

  Future<List<({int source, String lib, String title})>> _libs() async {
    final out = <({int source, String lib, String title})>[];
    final sources = (await api.call('GET', '/sources') as List).cast<Map>().where((s) => s['kind'] == 'audiobookshelf');
    for (final s in sources) {
      final res = await api.call('GET', '/sources/${s['id']}/browse');
      for (final l in itemsOf(res['items'])) {
        out.add((source: s['id'] as int, lib: l.key.split(':')[2], title: l.title));
      }
    }
    return out;
  }

  Future<Shelf> _load() async {
    libs ??= await _libs();
    if (libs!.isEmpty) throw t('No sources yet. Add one in the settings.');
    final l = libs![current.clamp(0, libs!.length - 1)];
    return Shelf(await api.call('GET', '/sources/${l.source}/books', query: {'parent': l.lib}) as Map);
  }

  void _setView(String v) => setState(() {
        view = v;
        author = null;
        series = null;
        Stores.device.put('books', {'view': v});
      });

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Loader<Shelf>(
        key: ValueKey('books/$current'),
        load: _load,
        builder: (context, shelf, _) => ListView(padding: const EdgeInsets.all(12), children: [
          if ((libs?.length ?? 0) > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                for (var i = 0; i < libs!.length; i++)
                  ChoiceChip(label: Text(libs![i].title), selected: i == current, onSelected: (_) => setState(() => current = i)),
              ]),
            ),
          TextField(
            controller: search,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: t('Search title, author, series, narrator'),
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
              for (final v in [('authors', t('Authors')), ('series', t('Series')), ('titles', t('Titles')), ('new', t('Recently added'))])
                ChoiceChip(
                  label: Text(v.$2),
                  showCheckmark: false,
                  selected: author == null && series == null && (_views.contains(view) ? view : 'authors') == v.$1,
                  onSelected: (_) => _setView(v.$1),
                ),
            ]),
            const SizedBox(height: 10),
          ],
          ..._content(context, shelf),
        ]),
      );

  List<Widget> _content(BuildContext context, Shelf shelf) {
    if (query.isNotEmpty) {
      final hits = shelf.books.where((b) => [b.item.title, b.author, b.series, b.narrator].any((s) => s.toLowerCase().contains(query))).toList();
      return hits.isEmpty ? [emptyText(context, t('Nothing found.'))] : [for (final b in hits) _book(context, b)];
    }
    if (series != null) {
      return [
        _head(context, series!.name, '${series!.author} · ${t('{a} of {b}', {'a': series!.heard, 'b': series!.total})}', () => setState(() => series = null)),
        for (final k in series!.books)
          if (shelf.byKey[k] != null) _book(context, shelf.byKey[k]!, next: k == series!.next),
      ];
    }
    if (author != null) {
      final mine = shelf.books.where((b) => b.author == author).toList();
      final rows = <Widget>[_head(context, author!, t('{n} books', {'n': mine.length}), () => setState(() => author = null))];
      for (final s in shelf.series.where((s) => s.books.any((k) => shelf.byKey[k]?.author == author))) {
        rows.add(_section(context, '${s.name} · ${t('{a} of {b}', {'a': s.heard, 'b': s.total})}'));
        for (final k in s.books) {
          final b = shelf.byKey[k];
          if (b != null && b.author == author) rows.add(_book(context, b, next: k == s.next));
        }
      }
      final loose = mine.where((b) => b.series.isEmpty).toList()..sort((a, b) => (a.item.year ?? 9999).compareTo(b.item.year ?? 9999));
      if (loose.isNotEmpty) {
        if (rows.length > 1) rows.add(_section(context, t('Without series')));
        rows.addAll(loose.map((b) => _book(context, b)));
      }
      return rows;
    }
    switch (view) {
      case 'series':
        return [
          for (final s in shelf.series)
            ItemRow(
              leading: CoverThumb(image: s.image, label: s.name),
              title: s.name,
              subtitle: [s.author, t('{a} of {b}', {'a': s.heard, 'b': s.total})].where((x) => x.isNotEmpty).join(' · '),
              progress: s.total == 0 ? null : s.heard / s.total,
              onTap: () => setState(() => series = s),
            ),
        ];
      case 'titles':
        return [for (final b in shelf.books) _book(context, b)];
      case 'new':
        final l = [...shelf.books]..sort((a, b) => (b.added ?? 0).compareTo(a.added ?? 0));
        return [for (final b in l.take(100)) _book(context, b)];
      default:
        return [
          for (final a in shelf.authors)
            ItemRow(
              leading: CoverThumb(label: a.name),
              title: a.name,
              subtitle: t('{n} books', {'n': a.books}),
              onTap: () => setState(() => author = a.name),
            ),
        ];
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

  Widget _section(BuildContext context, String s) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
        child: Text(s, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
      );

  Widget _book(BuildContext context, Book b, {bool next = false}) {
    final it = b.item, p = Stores.positions.get(it.key);
    final pos = (p?['position_ms'] as int?) ?? it.positionMs ?? 0;
    final done = (p?['finished'] as bool?) ?? it.finished;
    return ItemRow(
      leading: CoverThumb(image: it.image, label: it.title),
      title: it.title,
      subtitle: [
        if (next) t('Up next'),
        if (b.volume != null && b.series.isNotEmpty && query.isEmpty) t('Vol. {n}', {'n': b.volume!}),
        if (query.isNotEmpty || (author == null && series == null)) b.author,
        if (it.year != null) '${it.year}',
        if (it.durationMs != null) clock(it.durationMs!),
      ].where((s) => s.isNotEmpty).join(' · '),
      progress: !done && it.durationMs != null && it.durationMs! > 0 && pos > 0 ? pos / it.durationMs! : null,
      highlight: next,
      onTap: () => openDetails(context, it, widget.onPlay),
      trailing: [
        if (done) Icon(Icons.check_circle, color: context.tok.muted, semanticLabel: t('Heard')),
        saveOfflineButton(it),
        rowButton(t('Play'), () => startPlayback(context, [it], 0, widget.onPlay)),
      ],
    );
  }
}
