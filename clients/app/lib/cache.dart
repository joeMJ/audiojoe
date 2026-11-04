// The cache pill: how much of what plays now is saved on this device, and a tap saves the rest.
// Apps (user 2026-11-04): music the whole album (also when a single title of it was started), a
// book whole, a podcast only the episode playing. The web player in the car keeps its own rule.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'downloads.dart';
import 'models.dart';

/// The titles of an album ("jellyfin:2:abc" → browse parent abc of source 2), in album order.
Future<List<Item>> albumTracksOf(String album) async {
  final p = album.split(':');
  if (p.length < 3) return const [];
  final res = await api.call('GET', '/sources/${p[1]}/browse', query: {'parent': p[2], 'limit': '500'});
  return [for (final j in (res['items'] as List? ?? const [])) Item.fromJson((j as Map).cast<String, dynamic>())]
      .where((i) => i.kind == 'track')
      .toList();
}

/// What the pill saves for `item` played within `queue`; empty for radio and nothing playing.
Future<List<Item>> cacheScope(Item? item, List<Item> queue,
    {Future<List<Item>> Function(String album) tracksOf = albumTracksOf}) async {
  if (item == null) return const [];
  switch (item.kind) {
    case 'book':
    case 'episode':
      return [item];
    case 'track':
      final tracks = queue.where((i) => i.kind == 'track').toList();
      // Played as an album: the queue is the album.
      if (tracks.length > 1) return tracks;
      if (item.album != null) {
        try {
          final all = await tracksOf(item.album!);
          if (all.isNotEmpty) return all;
        } catch (_) {}
      }
      return [item];
    default:
      return const [];
  }
}

/// Saved share in per cent by playing time; a title without a known length counts as an average
/// one. 100 only when everything is there (as in the car).
int savedPercent(List<Item> items, OfflineEntry? Function(String key) entryOf) {
  if (items.isEmpty) return 0;
  final known = items.map((x) => x.durationMs ?? 0).where((d) => d > 0).toList();
  final avg = known.isEmpty ? 1.0 : known.reduce((a, b) => a + b) / known.length;
  var all = 0.0, have = 0.0;
  for (final x in items) {
    final w = (x.durationMs ?? 0) > 0 ? x.durationMs!.toDouble() : avg;
    final e = entryOf(x.key);
    all += w;
    have += e?.status == 'done' ? w : e?.status == 'loading' ? w * e!.progress : 0;
  }
  if (have >= all) return 100;
  return (have / all * 100).floor().clamp(0, 99);
}

/// The scope of the current title, asked once per title and queue.
class CacheScope {
  String _key = '';
  Future<List<Item>> _items = Future.value(const []);
  List<Item> last = const [];

  Future<List<Item>> of(Item? item, List<Item> queue) {
    final key = '${item?.key}|${queue.length}|${queue.isEmpty ? '' : queue.first.key}';
    if (key != _key) {
      _key = key;
      _items = cacheScope(item, queue).then((l) => last = l);
    }
    return _items;
  }

  @visibleForTesting
  void reset() => _key = '';
}
