// Desktop layout (Linux, Windows): player with the cover in the left third and buttons, Sonos
// volume and footer at the bottom of the right two thirds; no volume of this device; phone
// layout unchanged; settings on pages.

import 'package:audiojoe/models.dart';
import 'package:audiojoe/player.dart';
import 'package:audiojoe/sonos.dart';
import 'package:audiojoe/ui/common.dart';
import 'package:audiojoe/ui/now_playing.dart';
import 'package:audiojoe/ui/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

    testWidgets('Sonos: volume as its own row between buttons and footer, right of the cover', (tester) async {
      sonos.output = room(1, 'Living');
      await show(tester, const NowPlayingView());
      final v = rectOf(tester, volume('Volume'));
      expect(v.left, greaterThan(rectOf(tester, find.byType(CoverThumb)).right));
      expect(v.top, greaterThan(rectOf(tester, find.byTooltip('Pause')).bottom));
      expect(v.bottom, lessThan(rectOf(tester, find.text('Sonos Living')).top));
    });

    testWidgets('Sonos group: rooms open above the group volume', (tester) async {
      final members = [room(1, 'Living', group: [1, 2, 3]), room(2, 'Kitchen', group: [1, 2, 3]), room(3, 'Bath', group: [1, 2, 3])];
      sonos.all = members;
      sonos.output = members.first;
      await show(tester, const NowPlayingView());
      expect(find.text('Rooms (3)'), findsOneWidget);
      expect(volume('Kitchen'), findsNothing);
      await tester.tap(find.text('Rooms (3)'));
      await tester.pump();
      final kitchen = rectOf(tester, volume('Kitchen'));
      final groupVolume = rectOf(tester, volume('Group volume'));
      expect(kitchen.bottom, lessThan(groupVolume.top));
      expect(find.text('Group'), findsOneWidget);
      expect(groupVolume.bottom, lessThan(rectOf(tester, find.text('Living + 2')).top));
      expect(kitchen.left, greaterThan(rectOf(tester, find.byType(CoverThumb)).right));
    });

    testWidgets('a low window scrolls instead of overflowing', (tester) async {
      final members = [room(1, 'Living', group: [1, 2, 3]), room(2, 'Kitchen', group: [1, 2, 3]), room(3, 'Bath', group: [1, 2, 3])];
      sonos.all = members;
      sonos.output = members.first;
      await show(tester, const NowPlayingView(), size: const Size(900, 420));
      await tester.tap(find.text('Rooms (3)'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      // The footer stays in view, the title gives way.
      expect(rectOf(tester, find.text('Living + 2')).bottom, lessThanOrEqualTo(420));
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
      expect(find.text('John Lose (joeMJ)'), findsOneWidget);
      expect(find.byType(SettingsGroup), findsOneWidget);
    });

    testWidgets('phone: one list as before', (tester) async {
      desktop = false;
      await show(tester, SettingsView(onSignOut: () {}), size: const Size(400, 3000));
      expect(find.text('Add source'), findsOneWidget);
      expect(find.text('Import OPML'), findsOneWidget);
      expect(find.text('About audiojoe'), findsOneWidget);
      expect(find.byType(SettingsGroup), findsNothing);
    });
  });
}
