// Details of an episode, book or title on a page of its own: cover, facts, progress, shownotes,
// chapters. Nothing plays until a button is pressed. Also the header of an opened album.

import 'dart:math';

import 'package:flutter/material.dart';

import '../api.dart';
import '../l10n.dart';
import '../models.dart';
import '../store.dart';
import 'common.dart';
import 'lists.dart';
import 'notes.dart';
import 'views.dart';

Future<void> openDetails(BuildContext context, Item base, VoidCallback onPlay) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => DetailsPage(base: base, onPlay: onPlay)));

/// The full item from the server; offline what this device knows.
Future<Item> loadItem(Item base) async {
  try {
    return Item.fromJson((await api.call('GET', '/items/${Uri.encodeComponent(base.key)}') as Map).cast<String, dynamic>());
  } catch (_) {
    final known = Stores.items.get(base.key);
    return known == null ? base : Item.fromJson(known);
  }
}

String _date(String? published, int? year) {
  final d = published == null ? null : DateTime.tryParse(published);
  if (d != null) return '${d.day}.${d.month}.${d.year}';
  return published ?? (year == null ? '' : '$year');
}

class DetailsPage extends StatelessWidget {
  final Item base;
  final VoidCallback onPlay;
  const DetailsPage({super.key, required this.base, required this.onPlay});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(base.subtitle.isEmpty ? base.title : base.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis)),
        body: SafeArea(
          top: false,
          child: Loader<Item>(load: () => loadItem(base), builder: (context, it, _) => _body(context, it)),
        ),
      );

  Widget _body(BuildContext context, Item it) {
    final k = context.tok;
    final known = Stores.positions.get(it.key);
    final pos = it.playback?.positionMs ?? (known?['position_ms'] as int?) ?? it.positionMs ?? base.positionMs ?? 0;
    final finished = it.playback?.finished ?? (known?['finished'] as bool?) ?? it.finished;
    final dur = it.durationMs ?? base.durationMs;
    final facts = [
      _date(it.published, it.year),
      if (dur != null) clock(dur),
      ...it.genres,
      if (it.chapters.isNotEmpty) t('{n} chapters', {'n': it.chapters.length}),
      if (it.quality?.badge.isNotEmpty == true) it.quality!.badge,
    ].where((f) => f.isNotEmpty);
    final desc = it.description ?? base.description ?? '';
    return LayoutBuilder(
      builder: (context, c) => ListView(padding: const EdgeInsets.all(16), children: [
        Center(child: CoverThumb(image: it.image ?? base.image, label: it.subtitle.isEmpty ? it.title : it.subtitle, size: min(c.maxWidth - 32, 260))),
        const SizedBox(height: 16),
        Text(it.title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
        if (it.subtitle.isNotEmpty) Text(it.subtitle, style: TextStyle(fontSize: 16, color: k.muted, fontWeight: FontWeight.w600)),
        if ((it.series ?? '').isNotEmpty) Text(it.series!, style: TextStyle(color: k.muted)),
        const SizedBox(height: 10),
        Wrap(spacing: 6, runSpacing: 6, children: [for (final f in facts) Badge2(f)]),
        if (pos > 0 && !finished && dur != null && dur > 0) ...[
          const SizedBox(height: 14),
          LinearProgressIndicator(value: pos / dur, minHeight: 6, borderRadius: BorderRadius.circular(3), backgroundColor: k.panel2),
          const SizedBox(height: 4),
          Text('${clock(pos)} / ${clock(dur)}', style: TextStyle(color: k.muted)),
        ],
        const SizedBox(height: 14),
        Row(children: [
          FilledButton.icon(
            icon: const Icon(Icons.play_arrow),
            label: Text(pos > 0 && !finished ? t('Resume') : t('Play')),
            onPressed: () => startPlayback(context, [it], 0, onPlay),
          ),
          const SizedBox(width: 8),
          saveOfflineButton(it),
          if (it.kind == 'episode' || it.kind == 'book') NextButton(it),
        ]),
        const SizedBox(height: 20),
        Text(t('Description'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        Divider(color: k.line),
        if ((it.notes ?? '').isNotEmpty)
          NotesView(it.notes!)
        else
          SelectableText(desc.isEmpty ? t('No description.') : desc, style: TextStyle(fontSize: 15, height: 1.45, color: desc.isEmpty ? k.muted : null)),
        if (it.chapters.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text(t('Chapters'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          Divider(color: k.line),
          for (final ch in it.chapters)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                Expanded(child: Text(ch.title, style: const TextStyle(fontSize: 15))),
                Text(clock(ch.startMs), style: TextStyle(color: k.muted, fontFeatures: const [FontFeature.tabularFigures()])),
              ]),
            ),
        ],
        if (it.quality != null && it.quality!.codec.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text(t('Format'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          Divider(color: k.line),
          Text(it.quality!.text, style: const TextStyle(fontSize: 15)),
        ],
      ]),
    );
  }
}

/// Head of an opened album: cover, artist, year, genres, length, format and its description.
class AlbumHeader extends StatefulWidget {
  final Item album;
  final List<Item> tracks;
  final List<Widget> actions;
  const AlbumHeader({super.key, required this.album, required this.tracks, this.actions = const []});
  @override
  State<AlbumHeader> createState() => _AlbumHeaderState();
}

class _AlbumHeaderState extends State<AlbumHeader> {
  late final Future<Item> _full = loadItem(widget.album);
  bool open = false;

  @override
  Widget build(BuildContext context) => FutureBuilder<Item>(
        future: _full,
        builder: (context, s) {
          final a = s.data ?? widget.album, k = context.tok;
          final total = widget.tracks.fold<int>(0, (n, t) => n + (t.durationMs ?? 0));
          final q = widget.tracks.map((t) => t.quality?.badge ?? '').firstWhere((b) => b.isNotEmpty, orElse: () => '');
          final facts = [
            if (a.year != null) '${a.year}',
            ...a.genres,
            t('{n} titles', {'n': widget.tracks.length}),
            if (total > 0) clock(total),
            q,
          ].where((f) => f.isNotEmpty);
          final desc = a.description ?? '';
          return LayoutBuilder(
            builder: (context, c) {
              final wide = c.maxWidth >= 560;
              final cover = CoverThumb(image: a.image ?? widget.album.image, label: a.title, size: wide ? 200 : min(c.maxWidth, 300));
              final info = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(a.title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                if (a.subtitle.isNotEmpty) Text(a.subtitle, style: TextStyle(fontSize: 16, color: k.muted, fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                Wrap(spacing: 6, runSpacing: 6, children: [for (final f in facts) Badge2(f)]),
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: widget.actions),
                if (desc.isNotEmpty)
                  InkWell(
                    onTap: () => setState(() => open = !open),
                    child: Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: open && (a.notes ?? '').isNotEmpty
                          ? NotesView(a.notes!)
                          : Text(desc, maxLines: open ? null : 4, overflow: open ? null : TextOverflow.ellipsis, style: const TextStyle(height: 1.4)),
                    ),
                  ),
              ]);
              return Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: wide
                    ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [cover, const SizedBox(width: 18), Expanded(child: info)])
                    : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Center(child: cover), const SizedBox(height: 14), info]),
              );
            },
          );
        },
      );
}
