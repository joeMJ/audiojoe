// Desktop layout (Linux, Windows): player with the cover in the left third, buttons and footer
// fixed at the bottom right (in a low window the footer as 2 × 2 below the cover); no volume in
// the view, the output overlay has it; phone keeps its volume; settings on pages.

import 'dart:convert';

import 'package:audiojoe/api.dart';
import 'package:audiojoe/models.dart';
import 'package:audiojoe/player.dart';
import 'package:audiojoe/remote.dart';
import 'package:audiojoe/sonos.dart';
import 'package:audiojoe/ui/common.dart';
import 'package:audiojoe/ui/now_playing.dart';
import 'package:audiojoe/ui/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';

const episode = Item(key: 'episode:1', kind: 'episode', title: 'Episode 212', subtitle: 'Podcast', durationMs: 600000);
const radio = Item(key: 'radio:1', kind: 'radio', title: 'Radio One', subtitle: 'Jazz');

Room room(int id, String name, {List<int> group = const []}) =>
    Room(id, name, 'One', true, true, 'PLAYING', 35, group: group.isEmpty ? null : 'g', groupName: 'Living + 2', groupRooms: group);

Future<void> show(WidgetTester tester, Widget child, {Size size = const Size(1280, 720)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: buildTheme(Brightness.dark), home: Scaffold(body: child)));
  await tester.pump();
}

/// A volume row (− slider value +) by its label.
Finder volume(String label) => find.byWidgetPredicate((w) => w is Semantics && w.properties.label == label);
Rect rectOf(WidgetTester tester, Finder f) => tester.getRect(f);

void main() {
  setUp(() {
    desktop = true;
    player.item = episode;
    player.queue = [episode];
    remote.release();
    sonos.output = null;
    sonos.all = [];
  });
  tearDown(() => desktop = false);

  group('player, desktop', () {
    testWidgets('cover left third, buttons and footer at the bottom right, no volume', (tester) async {
      await show(tester, const NowPlayingView());
      final cover = rectOf(tester, find.byType(CoverThumb));
      final play = rectOf(tester, find.byTooltip('Play'));
      final title = rectOf(tester, find.text('Podcast'));
      final sleep = rectOf(tester, find.text('Sleep timer'));
      final screen = tester.view.physicalSize;
      // Cover: a square in the left third.
      expect(cover.left, 16);
      expect(cover.width, closeTo((screen.width - 32) / 3, 0.5));
      // Title at the top right, buttons below it, footer at the bottom, all right of the cover.
      for (final r in [title, play, sleep]) {
        expect(r.left, greaterThan(cover.right));
      }
      expect(title.top, lessThan(cover.top + 80));
      expect(play.top, greaterThan(title.bottom));
      expect(sleep.top, greaterThan(play.bottom));
      expect(sleep.bottom, greaterThan(screen.height - 80));
      expect(volume('Volume'), findsNothing);
      expect(find.byTooltip('Back 15 s'), findsOneWidget);
    });

    testWidgets('radio: only play/pause with Live', (tester) async {
      player.item = radio;
      player.queue = [radio];
      await show(tester, const NowPlayingView());
      expect(find.text('Live'), findsOneWidget);
      expect(find.byTooltip('Play'), findsOneWidget);
      expect(find.byTooltip('Back 15 s'), findsNothing);
      expect(find.byTooltip('Forward 30 s'), findsNothing);
      expect(find.byTooltip('Previous'), findsNothing);
      expect(rectOf(tester, find.byTooltip('Play')).left, greaterThan(rectOf(tester, find.byType(CoverThumb)).right));
    });

    testWidgets('Sonos: no volume in the view, where it plays below the facts, the room on the footer', (tester) async {
      sonos.output = room(1, 'Living');
      remote.controlRoom(sonos.output!);
      await show(tester, const NowPlayingView());
      expect(volume('Volume'), findsNothing);
      final where = rectOf(tester, find.text('Playing on Sonos Living'));
      expect(where.top, greaterThan(rectOf(tester, find.text('Podcast')).bottom));
      expect(where.bottom, lessThan(rectOf(tester, find.byTooltip('Pause')).top));
      expect(find.text('Living'), findsOneWidget);
      remote.release();
    });

    testWidgets('the footer button opens the output overlay: group volumes, apps, rooms', (tester) async {
      final members = [room(1, 'Living', group: [1, 2, 3]), room(2, 'Kitchen', group: [1, 2, 3]), room(3, 'Bath', group: [1, 2, 3])];
      Map j(Room r) => {'id': r.id, 'name': r.name, 'model': 'One', 's2': true, 'reachable': true, 'state': 'PLAYING', 'volume': 35,
            'group': 'g', 'group_name': 'Living + 2', 'group_rooms': [1, 2, 3]};
      api.device = 'Linux';
      api.client = MockClient((req) async => http.Response(
          jsonEncode(switch (req.url.path) {
            '/api/v1/devices' => [
                {'device': 'Linux', 'kind': 'linux', 'state': 'paused', 'online': true, 'current': true},
                {'device': 'Pixel 8', 'kind': 'android', 'state': 'paused', 'key': 'episode:1', 'title': 'Episode 212',
                 'position_ms': 760000, 'online': true},
                {'device': 'Firefox', 'kind': 'web', 'state': 'playing', 'key': 'episode:1', 'title': 'Episode 212',
                 'position_ms': 1000, 'online': true},
                {'device': 'Windows', 'kind': 'windows', 'state': 'stopped', 'online': false, 'last_seen': '2026-11-02T12:00:00Z'},
              ],
            '/api/v1/sonos' => [for (final r in members) j(r), {'id': 4, 'name': 'Office', 'reachable': true, 'busy': true},
                {'id': 5, 'name': 'Garden', 'reachable': false}],
            _ => [],
          }),
          200,
          headers: {'content-type': 'application/json'}));
      sonos.all = members;
      sonos.output = members.first;
      remote.controlRoom(members.first);
      await show(tester, const NowPlayingView(), size: const Size(1100, 1600));
      await tester.tap(find.text('Living + 2'));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Output'), findsOneWidget);
      for (final v in ['Group', 'Living', 'Kitchen', 'Bath']) {
        expect(volume(v), findsOneWidget, reason: v);
      }
      expect(find.text('Here'), findsNWidgets(3)); // the group, Pixel 8, the offline Windows app
      expect(find.text('Control'), findsNWidgets(2)); // Pixel 8 and the offline Windows app
      expect(find.text('Take over'), findsOneWidget);
      expect(find.text('Web player · Firefox'), findsOneWidget);
      expect(find.text('This device · Linux'), findsOneWidget);
      expect(find.text('busy'), findsOneWidget);
      expect(find.text('switched off'), findsOneWidget);
      // A busy or switched-off room cannot be chosen; the free ones of the group are controlled.
      final there = tester.widgetList<FilledButton>(find.widgetWithText(FilledButton, 'There')).toList();
      expect(there.length, 2);
      expect(there.every((b) => b.onPressed == null), isTrue);
      await tester.tap(find.byTooltip('Close'));
      await tester.pump();
      expect(find.text('Output'), findsNothing);
      expect(find.byTooltip('Pause'), findsOneWidget);
      remote.release();
    });

    testWidgets('a low window: the footer as 2 × 2 below the cover, the buttons stay at the bottom right', (tester) async {
      await show(tester, const NowPlayingView(), size: const Size(640, 430));
      expect(tester.takeException(), isNull);
      final cover = rectOf(tester, find.byType(CoverThumb));
      final sleep = rectOf(tester, find.text('Sleep timer'));
      final speed = rectOf(tester, find.text('Speed'));
      final output = rectOf(tester, find.text('This device'));
      final play = rectOf(tester, find.byTooltip('Play'));
      expect(sleep.top, greaterThan(cover.bottom));
      expect(sleep.right, lessThanOrEqualTo(cover.right + 1));
      expect(speed.top, sleep.top);
      expect(output.top, greaterThan(sleep.bottom));
      expect(play.left, greaterThan(cover.right));
      expect(play.bottom, lessThanOrEqualTo(430));
      expect(rectOf(tester, find.byTooltip('Back 15 s')).bottom, lessThanOrEqualTo(430));
    });
  });

  group('player, phone', () {
    setUp(() => desktop = false);

    testWidgets('phone keeps the volume of this device above the footer', (tester) async {
      await show(tester, const NowPlayingView(), size: const Size(400, 800));
      expect(volume('Volume'), findsOneWidget);
      final cover = rectOf(tester, find.byType(CoverThumb));
      expect(rectOf(tester, find.byTooltip('Play')).top, greaterThan(cover.bottom));
      expect(find.text('Group'), findsNothing);
    });
  });

  group('settings', () {
    setUp(() => PackageInfo.setMockInitialValues(
        appName: 'audiojoe', packageName: 'audiojoe', version: '0.1.0', buildNumber: '1', buildSignature: ''));

    testWidgets('desktop: pages on the left, one page at a time', (tester) async {
      await show(tester, SettingsView(onSignOut: () {}));
      for (final p in ['Sources', 'Podcasts', 'Music', 'Sonos', 'Devices', 'Maintenance', 'About']) {
        expect(find.text(p), findsWidgets, reason: p);
      }
      expect(find.text('Add source'), findsOneWidget);
      expect(find.text('Import OPML'), findsNothing);

      await tester.tap(find.text('Podcasts'));
      await tester.pump();
      expect(find.text('Import OPML'), findsOneWidget);
      expect(find.text('Sync with other podcast apps'), findsOneWidget);
      expect(find.text('Add source'), findsNothing);

      await tester.tap(find.text('Devices'));
      await tester.pump();
      expect(find.text('Sign out this device'), findsOneWidget);

      await tester.tap(find.text('About'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Third-party licences'), findsOneWidget);
      expect(find.text('App 0.1.0'), findsOneWidget);
      expect(find.text('John Lose (joeMJ)'), findsNWidgets(2));
      expect(find.byType(SettingsGroup), findsNWidgets(2));
      expect(find.text('Contributors'), findsOneWidget);
      expect(find.text('© 2026 John Lose · Apache-2.0'), findsOneWidget);
    });

    testWidgets('phone: list of the pages with their state, a tap opens one, back returns', (tester) async {
      desktop = false;
      api.client = MockClient((req) async => http.Response(
          jsonEncode(switch (req.url.path) {
            '/api/v1/sources' => [{'id': 1, 'name': 'Jellyfin', 'kind': 'jellyfin', 'url': 'https://jf.example'}],
            '/api/v1/sources/1/libraries' => [{'id': 'a', 'title': 'Music'}, {'id': 'b', 'title': 'Books'}],
            '/api/v1/sonos/setup' => {'enabled': true},
            '/api/v1/sonos' => [{'name': 'Kitchen'}, {'name': 'Bath'}],
            '/api/v1/sessions' => [{'id': 1, 'device': 'phone', 'current': true, 'last_seen': '2026-11-02T12:00:00Z'}],
            '/api/v1/maintenance' => {'version': '0.1.4', 'managed': true, 'status': {'latest': '0.1.4'}},
            _ => [],
          }),
          200,
          headers: {'content-type': 'application/json'}));
      await show(tester, SettingsView(onSignOut: () {}), size: const Size(360, 760));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      for (final p in ['Sources', 'Podcasts', 'Music', 'Sonos', 'Devices', 'Maintenance', 'About']) {
        expect(find.text(p), findsOneWidget, reason: p);
      }
      expect(find.text('Jellyfin · 2 libraries'), findsOneWidget);
      expect(find.text('2 speakers'), findsOneWidget);
      expect(find.text('1 signed in · sign out this device'), findsOneWidget);
      expect(find.text('Server 0.1.4 · App 0.1.0 · update available'), findsOneWidget);
      expect(find.text('Storage'), findsNothing); // "Ablage" comes with 0.2.0
      expect(find.text('Import OPML'), findsNothing);

      await tester.tap(find.text('Podcasts'));
      await tester.pump();
      expect(find.text('Import OPML'), findsOneWidget);
      expect(find.text('Sources'), findsNothing);
      await tester.tap(find.byTooltip('Back'));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Sources'), findsOneWidget);

      await tester.tap(find.text('Devices'));
      await tester.pump();
      expect(find.text('Sign out this device'), findsOneWidget);
    });
  });
}
