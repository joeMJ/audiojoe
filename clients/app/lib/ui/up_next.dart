// "Up next" (user 2026-11-04, in place of "Offline" in the player's footer): what plays now and
// after it – the titles of the album, the chapters of a book, for a podcast the following
// episodes of the continue list. Playing on another device: that device's queue.

import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../l10n.dart';
import '../models.dart';
import '../player.dart';
import '../remote.dart';
import 'common.dart';
import 'lists.dart';

/// One line of the list: its title, a second line, whether it is the current one, and what a tap does.
typedef UpNextRow = ({String title, String subtitle, bool current, Future<void> Function()? play});

/// The rows for what plays now. `queue` and `index` are this device's, or the controlled one's.
Future<List<UpNextRow>> upNextRows(Item it, List<Item> queue, int index,
    {bool local = true, Future<List<ListEntry>> Function(String list) load = loadList}) async {
  String len(int? ms) => ms == null || ms <= 0 ? '' : clock(ms);
  switch (it.kind) {
    case 'episode':
      final list = await load('podcasts');
      final i = list.indexWhere((e) => e.key == it.key);
      final next = i < 0 ? list : list.sublist(i + 1);
      return [
        (title: it.title, subtitle: it.subtitle, current: true, play: null),
        for (final e in next)
          (title: e.title, subtitle: e.subtitle, current: false, play: local ? () => playEntry(null, 'podcasts', e, null) : null),
      ];
    case 'book':
      if (it.chapters.isNotEmpty) {
        final c = player.chapterIndex;
        return [
          for (final (i, ch) in it.chapters.indexed)
            (title: ch.title, subtitle: len(ch.endMs - ch.startMs), current: i == c, play: () => player.seekTo(ch.startMs)),
        ];
      }
      return [(title: it.title, subtitle: it.subtitle, current: true, play: null)];
    default:
      if (queue.isEmpty) return [(title: it.title, subtitle: it.subtitle, current: true, play: null)];
      return [
        for (final (i, q) in queue.indexed)
          (
            title: q.title,
            subtitle: [if (q.track != null) '${q.track}', len(q.durationMs)].where((s) => s.isNotEmpty).join(' · '),
            current: i == index,
            play: local && i != index ? () => player.skip(i - index) : null,
          ),
      ];
  }
}

/// The entry after the current one, for the small line "Up next: …" below the format chips (user
/// 2026-11-09, "107–109 ja"): in an album the next title, in a book the next chapter, for a podcast the
/// next episode of the continue list. Radio and the last entry: none.
Future<String?> upNextTitle(Item it, List<Item> queue, int index,
    {Future<List<ListEntry>> Function(String list) load = loadList}) async {
  if (it.kind == 'radio') return null;
  final rows = await upNextRows(it, queue, index, local: false, load: load);
  final i = rows.indexWhere((r) => r.current);
  return i >= 0 && i + 1 < rows.length ? rows[i + 1].title : null;
}

/// The same for what plays now: this device's queue, or the controlled device's.
Future<String?> upNextNow(Item it) async {
  if (remote.active) {
    final q = await _otherQueue(it.key);
    return upNextTitle(it, q.items, q.index);
  }
  return upNextTitle(it, player.queue, player.index);
}

/// The queue another device left with `key` as its current title (server: /queue/{key}).
Future<({List<Item> items, int index})> _otherQueue(String key) async {
  try {
    final q = await api.call('GET', '/queue/${Uri.encodeComponent(key)}') as Map;
    final items = [for (final j in q['items'] as List? ?? const []) Item.fromJson((j as Map).cast<String, dynamic>())];
    return (items: items, index: (q['index'] as int?) ?? 0);
  } catch (_) {
    return (items: <Item>[], index: 0);
  }
}

void showUpNext(BuildContext context, Item it) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.75),
          child: FutureBuilder<List<UpNextRow>>(
            future: () async {
              if (remote.active) {
                final q = await _otherQueue(it.key);
                return upNextRows(it, q.items, q.index, local: false);
              }
              return upNextRows(it, player.queue, player.index);
            }(),
            builder: (ctx, snap) {
              final k = ctx.tok, accent = Theme.of(ctx).colorScheme.primary;
              final rows = snap.data;
              return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                ListTile(title: Text(t('Up next'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
                if (rows == null)
                  const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
                else
                  Flexible(
                    child: ListView(shrinkWrap: true, key: const ValueKey('up-next'), children: [
                      for (final r in rows)
                        ListTile(
                          leading: Icon(r.current ? Icons.play_arrow : Icons.queue_music, color: r.current ? accent : k.muted),
                          title: Text(r.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontWeight: r.current ? FontWeight.w800 : FontWeight.w500, color: r.current ? accent : null)),
                          subtitle: r.subtitle.isEmpty ? null : Text(r.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                          onTap: r.play == null
                              ? null
                              : () {
                                  Navigator.pop(ctx);
                                  unawaited(r.play!());
                                },
                        ),
                    ]),
                  ),
              ]);
            },
          ),
        ),
      ),
    );
