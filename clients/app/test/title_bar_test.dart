// 0.1.7 title bar (user 2026-11-04): Linux and Windows draw it themselves – line icon, "audiojoe"
// and the version on the left; Cache, Server, Position, Storage and the round moon on the right,
// in the car's order. The cache pill: a frame only for radio and playback elsewhere; the storage
// pill turns red below "Keep at least … free".

import 'dart:io';

import 'package:audiojoe/downloads.dart';
import 'package:audiojoe/models.dart';
import 'package:audiojoe/player.dart';
import 'package:audiojoe/remote.dart';
import 'package:audiojoe/sonos.dart';
import 'package:audiojoe/storage.dart';
import 'package:audiojoe/store.dart';
import 'package:audiojoe/ui/common.dart';
import 'package:audiojoe/ui/title_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const episode = Item(key: 'episode:1', kind: 'episode', title: 'Episode 212', subtitle: 'Podcast', durationMs: 600000);
const radio = Item(key: 'radio:1', kind: 'radio', title: 'Radio One');

Future<void> frame(WidgetTester tester, {bool signedIn = true, Brightness b = Brightness.dark}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(b),
    builder: (context, child) => DesktopFrame(signedIn: signedIn, child: child!),
    home: const Scaffold(body: SizedBox()),
  ));
  await tester.pump();
  await tester.pump();
}

String cacheText(WidgetTester tester) =>
    (tester.widget<Text>(find.descendant(of: find.byKey(const ValueKey('cache-pill')), matching: find.byType(Text))).data)!;

void main() {
  setUpAll(() async {
    Stores.dir = Directory.systemTemp.createTempSync('audiojoe-test');
    for (final s in [Stores.device, Stores.offline, Stores.items]) {
      await s.open(Stores.dir);
    }
  });

  setUp(() {
    desktop = true;
    withWindowButtons = false;
    appVersion = '0.1.7';
    player.item = episode;
    player.queue = [episode];
    remote.release();
    sonos.output = null;
    storage.free = null;
    Stores.offline.data.clear();
  });
  tearDown(() => desktop = false);

  testWidgets('name and version left, pills in the car order right, round moon last', (tester) async {
    await frame(tester);
    final icon = tester.getRect(find.byType(Image));
    final name = tester.getRect(find.byKey(const ValueKey('app-name')));
    final version = tester.getRect(find.byKey(const ValueKey('app-version')));
    expect(icon.left, lessThan(40));
    expect(name.left, greaterThan(icon.right));
    expect(version.left, greaterThan(name.right));
    expect(find.text('0.1.7'), findsOneWidget);
    final order = [
      find.byKey(const ValueKey('cache-pill')),
      find.text('Server'),
      find.text('Position'),
      find.byKey(const ValueKey('storage-pill')),
      find.byKey(const ValueKey('moon')),
    ].map((f) => tester.getRect(f).left).toList();
    for (var i = 1; i < order.length; i++) {
      expect(order[i], greaterThan(order[i - 1]), reason: 'position $i');
    }
    expect(order.first, greaterThan(640), reason: 'pills on the right');
    // The moon is round and as high as the pills.
    final moon = tester.getRect(find.byKey(const ValueKey('moon')));
    expect(moon.width, moon.height);
    expect(moon.height, closeTo(tester.getRect(find.byKey(const ValueKey('storage-pill'))).height, 3));
    // No size on the storage pill and no "Offline" pill any more.
    expect(find.text('Storage'), findsOneWidget);
    expect(find.textContaining('GB'), findsNothing);
    expect(find.text('Offline'), findsNothing);
  });

  testWidgets('signed out: the bar with the moon, no pills', (tester) async {
    await frame(tester, signedIn: false);
    expect(find.byKey(const ValueKey('app-name')), findsOneWidget);
    expect(find.byKey(const ValueKey('moon')), findsOneWidget);
    expect(find.byKey(const ValueKey('cache-pill')), findsNothing);
  });

  testWidgets('cache pill: share of the episode; a frame only for radio and other devices', (tester) async {
    await frame(tester);
    expect(cacheText(tester), 'Cache 0 %');
    Stores.offline.put(episode.key, OfflineEntry(episode.key, '', '', '', status: 'done', progress: 1).toJson());
    downloads.notifyListeners();
    await tester.pump();
    await tester.pump();
    expect(cacheText(tester), 'Cache 100 %');

    player.item = radio;
    player.queue = [radio];
    player.notifyListeners();
    await tester.pump();
    expect(cacheText(tester), 'Cache');

    player.item = episode;
    player.queue = [episode];
    sonos.output = Room(1, 'Kitchen', 'One', true, true, 'PLAYING', 35);
    sonos.notifyListeners();
    await tester.pump();
    expect(cacheText(tester), 'Cache');
    sonos.output = null;
    await tester.pump(const Duration(seconds: 1)); // the store's save timer
  });

  testWidgets('storage pill red below the limit', (tester) async {
    await frame(tester);
    Color colorOf() => tester.widget<Text>(find.descendant(of: find.byKey(const ValueKey('storage-pill')), matching: find.byType(Text))).style!.color!;
    final normal = colorOf();
    storage.free = 4 * gb;
    storage.notifyListeners();
    await tester.pump();
    expect(colorOf(), isNot(normal));
    expect(colorOf(), Tok.dark.bad);
  });

  testWidgets('moon: a tap switches dark mode', (tester) async {
    await frame(tester);
    final wasDark = find.byIcon(Icons.dark_mode).evaluate().isNotEmpty;
    await tester.tap(find.byKey(const ValueKey('moon')));
    await tester.pump();
    expect(find.byIcon(wasDark ? Icons.dark_mode_outlined : Icons.dark_mode), findsOneWidget);
    await tester.pump(const Duration(seconds: 1)); // the store's save timer
  });
}
