// "Up next: …" below the format chips (user 2026-11-09, "107 ja 108 ja 109 ja"): in an album the next
// title, in a book the next chapter, for a podcast the next episode of the continue list; radio and
// the last entry show nothing.

import 'dart:io';

import 'package:audiojoe/models.dart';
import 'package:audiojoe/player.dart';
import 'package:audiojoe/store.dart';
import 'package:audiojoe/ui/lists.dart';
import 'package:audiojoe/ui/up_next.dart';
import 'package:flutter_test/flutter_test.dart';

Item track(int n) => Item(key: 'jellyfin:1:t$n', kind: 'track', title: 'Title $n', track: n);
Item episode(int n) => Item(key: 'episode:$n', kind: 'episode', title: 'Episode $n', subtitle: 'Show');
ListEntry entry(Item it) => ListEntry({'key': it.key, 'title': it.title, 'subtitle': it.subtitle});

void main() {
  setUpAll(() async {
    Stores.dir = Directory.systemTemp.createTempSync('audiojoe-test');
    for (final s in [Stores.device, Stores.offline, Stores.items]) {
      await s.open(Stores.dir);
    }
  });

  final album = [track(1), track(2), track(3)];
  Future<List<ListEntry>> none(String _) async => [];

  test('album: the next title, after the last none', () async {
    expect(await upNextTitle(album[0], album, 0, load: none), 'Title 2');
    expect(await upNextTitle(album[1], album, 1, load: none), 'Title 3');
    expect(await upNextTitle(album[2], album, 2, load: none), isNull);
  });

  test('a single title: none', () async {
    expect(await upNextTitle(album[0], [album[0]], 0, load: none), isNull);
  });

  test('radio: none, also in a queue of stations', () async {
    const a = Item(key: 'radio:a', kind: 'radio', title: 'DLF');
    const b = Item(key: 'radio:b', kind: 'radio', title: 'WDR');
    expect(await upNextTitle(a, [a, b], 0, load: none), isNull);
  });

  test('podcast: the next episode of the continue list', () async {
    final list = [episode(1), episode(2), episode(3)];
    Future<List<ListEntry>> load(String l) async => l == 'podcasts' ? [for (final e in list) entry(e)] : [];
    expect(await upNextTitle(list[1], [list[1]], 0, load: load), 'Episode 3');
    expect(await upNextTitle(list[2], [list[2]], 0, load: load), isNull);
    // Not in the list (e.g. played from the show page): the first entry of the list.
    expect(await upNextTitle(episode(9), [episode(9)], 0, load: load), 'Episode 1');
  });

  test('book: the next chapter, after the last none', () async {
    const book = Item(key: 'book:1', kind: 'book', title: 'Book', chapters: [
      Chapter('Prologue', 0, 60000),
      Chapter('One', 60000, 120000),
    ]);
    player.item = book;
    player.queue = [book];
    // Position 0: chapter 1 of 2.
    expect(await upNextTitle(book, [book], 0, load: none), 'One');
    player.item = null;
    player.queue = [];
  });
}
