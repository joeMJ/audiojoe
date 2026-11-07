// End-to-end test of the desktop app against a running server (Linux, under Xvfb).
//
//   flutter test integration_test -d linux \
//     --dart-define=SERVER=https://audio.example.org --dart-define=USER=… \
//     --dart-define=PASS=… --dart-define=TOTP_SECRET=…
//
// Signs in through the UI, opens podcasts, plays an episode, checks that the position
// reaches the server, saves it offline and plays it from the offline copy, signs out. With
// --dart-define=SHOTS=DIR also screenshots of player and settings, light and dark (X screen,
// ImageMagick "import"); Sonos only as state shown, nothing is sent to a speaker.

import 'dart:io';

import 'package:audiojoe/api.dart';
import 'package:audiojoe/appearance.dart';
import 'package:audiojoe/downloads.dart';
import 'package:audiojoe/main.dart' as app;
import 'package:audiojoe/models.dart';
import 'package:audiojoe/player.dart';
import 'package:audiojoe/remote.dart';
import 'package:audiojoe/sonos.dart';
import 'package:audiojoe/storage.dart';
import 'package:audiojoe/ui/shell.dart' show shellPage;
import 'package:audiojoe/ui/common.dart' show desktop;
import 'package:audiojoe/updates.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const server = String.fromEnvironment('SERVER');
const user = String.fromEnvironment('USER');
const pass = String.fromEnvironment('PASS');
const secret = String.fromEnvironment('TOTP_SECRET');
const feed = 'https://feeds.lagedernation.org/feeds/ldn-mp3.xml';
const shots = String.fromEnvironment('SHOTS');

/// The X screen in light and dark as SHOTS/NAME-light.png and -dark.png.
Future<void> shot(WidgetTester tester, String name) async {
  if (shots.isEmpty) return;
  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    appearance.value = mode;
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    final r = await Process.run('import', ['-window', 'root', '$shots/$name-${mode.name}.png']);
    expect(r.exitCode, 0, reason: '${r.stderr}');
  }
  appearance.value = ThemeMode.system;
}

String totp(String base32, DateTime now) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  final bits = base32.replaceAll('=', '').split('').map((c) => alphabet.indexOf(c).toRadixString(2).padLeft(5, '0')).join();
  final key = [for (var i = 0; i + 8 <= bits.length; i += 8) int.parse(bits.substring(i, i + 8), radix: 2)];
  final counter = now.millisecondsSinceEpoch ~/ 1000 ~/ 30;
  final msg = ByteData(8)..setInt64(0, counter);
  final h = Hmac(sha1, key).convert(msg.buffer.asUint8List()).bytes;
  final o = h.last & 15;
  final v = ((h[o] & 0x7f) << 24) | (h[o + 1] << 16) | (h[o + 2] << 8) | h[o + 3];
  return (v % 1000000).toString().padLeft(6, '0');
}

Future<void> waitFor(WidgetTester tester, Finder f, {int seconds = 30}) async {
  for (var i = 0; i < seconds * 4; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    if (f.evaluate().isNotEmpty) return;
  }
  throw TestFailure('not found within $seconds s: $f');
}

Future<void> waitUntil(WidgetTester tester, bool Function() cond, {int seconds = 30, String what = ''}) async {
  for (var i = 0; i < seconds * 4; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    if (cond()) return;
  }
  throw TestFailure('condition not met within $seconds s: $what');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sign in, podcast, play, sync, offline', (tester) async {
    await app.main();
    await tester.pumpAndSettle();

    // ---------------------------------------------------------- sign in through the UI
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(5));
    // The code may be used only once: wait for a fresh 30 s step.
    await Future.delayed(Duration(seconds: 31 - DateTime.now().second % 30));
    await tester.enterText(fields.at(0), server);
    await tester.enterText(fields.at(1), user);
    await tester.enterText(fields.at(2), pass);
    await tester.enterText(fields.at(3), totp(secret, DateTime.now()));
    await tester.enterText(fields.at(4), 'Linux (Test)');
    await tester.tap(find.byType(FilledButton));
    await waitFor(tester, find.byTooltip('Server reachable'));

    // ---------------------------------------------------------- podcast
    final sub = await api.call('POST', '/podcasts', body: {'feed_url': feed}) as Map;
    await tester.tap(find.text('Podcasts').last);
    await waitFor(tester, find.textContaining('LdN'));
    final eps = (await api.call('GET', '/podcasts/${sub['id']}/episodes', query: {'limit': '200'}) as List)
        .map((e) => Item.fromJson((e as Map).cast<String, dynamic>()))
        .where((e) => e.durationMs != null)
        .toList()
      ..sort((a, b) => a.durationMs!.compareTo(b.durationMs!));
    final ep = Item(key: eps.first.key, kind: 'episode', title: eps.first.title, subtitle: eps.first.subtitle);

    // ---------------------------------------------------------- play, position on the server
    await player.play([ep]);
    await waitUntil(tester, () => player.playing && player.position > 3000, what: 'playing');
    await player.seekTo(120000);
    await tester.pump(const Duration(seconds: 2));
    player.toggle(); // pause → saves
    await tester.pump(const Duration(seconds: 3));
    final pb = await api.call('GET', '/playback/${Uri.encodeComponent(ep.key)}') as Map;
    expect(pb['device'], 'Linux (Test)');
    expect((pb['position_ms'] as int) >= 120000 && (pb['position_ms'] as int) < 130000, isTrue, reason: 'position ${pb['position_ms']}');

    // ---------------------------------------------------------- desktop layout, title bar
    // The window answers "dark" (GTK header bar follows the moon button).
    await const MethodChannel('io.github.joemj.audiojoe/window').invokeMethod('dark', true);
    await const MethodChannel('io.github.joemj.audiojoe/window').invokeMethod('dark', false);
    await tester.tap(find.text('Now playing').first);
    await waitFor(tester, find.byTooltip('Play'));
    // 0.1.7: the own title bar – name and version, Cache, Server, Position, Storage, moon.
    expect(find.byKey(const ValueKey('app-name')), findsOneWidget);
    expect(find.byKey(const ValueKey('app-version')), findsOneWidget);
    expect(find.byKey(const ValueKey('storage-pill')), findsOneWidget);
    await waitUntil(tester, () => find.textContaining('Cache 0 %').evaluate().isNotEmpty, seconds: 10, what: 'cache pill');
    // "Up next" in the footer instead of "Offline".
    expect(find.text('Up next'), findsOneWidget);
    await tester.tap(find.text('Up next'));
    await waitFor(tester, find.byKey(const ValueKey('up-next')));
    await tester.pump(const Duration(seconds: 1));
    await shot(tester, 'up-next');
    await tester.tapAt(const Offset(640, 100)); // above the sheet, below the title bar
    await tester.pump(const Duration(seconds: 1));
    // No volume of this device on the desktop.
    expect(find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'Volume'), findsNothing);
    await shot(tester, 'player');
    // Sonos as shown state only (no request to a speaker): one room, then a group with rooms open.
    Future<void> again() async {
      await tester.tap(find.text('Continue').first);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Now playing').first);
      await tester.pump(const Duration(milliseconds: 500));
    }
    final rooms = [
      for (final (i, n) in ['Wohnzimmer', 'Küche', 'Bad'].indexed)
        Room(i + 1, n, 'One', true, true, 'PAUSED_PLAYBACK', 35 - 10 * i, group: 'g', groupName: 'Wohnzimmer + 2', groupRooms: const [1, 2, 3]),
    ];
    sonos.output = Room(1, 'Wohnzimmer', 'One', true, true, 'PAUSED_PLAYBACK', 35);
    remote.controlRoom(sonos.output!);
    await again();
    await shot(tester, 'player-sonos');
    sonos.all = rooms;
    sonos.output = rooms.first;
    remote.controlRoom(rooms.first);
    await again();
    expect(find.text('Playing on Sonos Wohnzimmer + 2'), findsOneWidget);
    // The footer button opens the output overlay (devices and rooms as the server lists them).
    await tester.tap(find.text('Wohnzimmer + 2'));
    await waitFor(tester, find.text('APPS AND WEB PLAYER'));
    await tester.pump(const Duration(seconds: 2));
    // 0.1.9: Snooze in the controlled field; with the speaker's sleep timer running its minutes.
    expect(find.text('Snooze'), findsOneWidget);
    sonos.output!.sleepS = 1380;
    remote.controlRoom(sonos.output!); // redraws (no request to a speaker)
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Snooze · 23 min'), findsOneWidget);
    await shot(tester, 'output-overlay');
    await tester.tap(find.byTooltip('Close'));
    await tester.pump(const Duration(milliseconds: 500));
    remote.release();
    sonos.all = [];
    // The smallest window: footer as 2 × 2 below the cover, buttons at the bottom right.
    await tester.binding.setSurfaceSize(const Size(720, 540));
    await again();
    expect(tester.takeException(), isNull);
    await shot(tester, 'player-720x540');
    await tester.binding.setSurfaceSize(null);
    await again();
    await tester.tap(find.text('Settings').first);
    await waitFor(tester, find.text('Add source'));
    await shot(tester, 'settings-sources');
    for (final name in ['podcasts', 'storage', 'devices', 'maintenance', 'about']) {
      await tester.tap(find.byKey(ValueKey('settings-page-$name')));
      await tester.pump(const Duration(seconds: 2));
      await shot(tester, 'settings-$name');
    }

    // Phone layout (Android) at 360 × 760: the settings as a list of pages, a tap opens one.
    // Shots only (top left 360 × 760 of the X screen).
    if (shots.isNotEmpty) {
      desktop = false;
      await tester.binding.setSurfaceSize(const Size(360, 760));
      await waitFor(tester, find.text('Settings'));
      await tester.tap(find.text('Settings').last);
      // Since the page "Playback" (0.1.8) the list is longer than 760 px: "Maintenance" with its line
      // "Server … · App …" is below the screen and not built yet; wait for a line near the top and
      // scroll to each page before tapping it.
      await waitFor(tester, find.textContaining('10 s back'));
      await shot(tester, 'phone-settings');
      for (final (page, name) in [('Sources', 'sources'), ('Playback', 'playback'), ('Storage', 'storage'), ('Appearance', 'appearance'), ('Maintenance', 'maintenance')]) {
        await tester.scrollUntilVisible(find.text(page), 120, scrollable: find.byType(Scrollable).first);
        await tester.tap(find.text(page));
        await tester.pump(const Duration(seconds: 2));
        await shot(tester, 'phone-$name');
        await tester.tap(find.byTooltip('Back'));
        await waitFor(tester, find.text('Settings'));
        await tester.pump(const Duration(seconds: 2));
      }
      desktop = true;
      await tester.binding.setSurfaceSize(null);
      await tester.pump(const Duration(seconds: 1));
    }

    // ---------------------------------------------------------- offline copy
    // 0.2.0: into the sub-folder podcasts of the storage folder (a folder of this test).
    final root = Directory('${Directory.systemTemp.path}/audiojoe-it-$pid');
    storage.dir = root;
    await downloads.add([ep]);
    expect(downloads.entry(ep.key)!.dir, '${root.path}/podcasts');
    await waitUntil(tester, () => downloads.isOffline(ep.key), seconds: 300, what: 'offline download');
    expect(downloads.file(ep.key).existsSync(), isTrue);
    expect(File('${downloads.file(ep.key).path}.part').existsSync(), isFalse);
    shellPage.value = 7;
    await waitFor(tester, find.byKey(ValueKey('download-${ep.key}')));
    await shot(tester, 'downloads');
    if (shots.isNotEmpty) {
      desktop = false;
      await tester.binding.setSurfaceSize(const Size(360, 760));
      await tester.pump(const Duration(seconds: 2));
      await shot(tester, 'phone-downloads');
      desktop = true;
      await tester.binding.setSurfaceSize(null);
      await tester.pump(const Duration(seconds: 1));
    }
    shellPage.value = 1;
    await tester.pump(const Duration(seconds: 1));
    await player.play([ep]);
    expect(player.fromCache, isTrue);
    await waitUntil(tester, () => player.playing, what: 'playing from file');
    final at = player.position;
    await tester.pump(const Duration(seconds: 3));
    expect(player.position > at, isTrue, reason: 'position advances from the offline file');
    await player.stop();

    // ---------------------------------------------------------- app update: download + SHA-256
    // The Linux installer of the newest release through the server, checked against its SHA256SUMS
    // (only when the server knows a release; installing is not part of this test).
    final apps = (await api.call('GET', '/maintenance') as Map)['apps'] as Map?;
    if (apps?['linux'] != null) {
      final u = AppUpdate(latest: '${apps!['latest']}', name: '${apps['linux']['name']}', platform: 'linux');
      final f = await downloadAppUpdate(u, (_, _) {});
      expect(f.lengthSync(), greaterThan(1000000), reason: 'the checked package is kept');
      // ignore: avoid_print
      print('app update: ${u.name} downloaded and checked (${f.lengthSync()} bytes)');
      await f.delete();
    }

    // ---------------------------------------------------------- cleanup
    await downloads.remove(ep.key);
    if (root.existsSync()) root.deleteSync(recursive: true);
    await api.call('DELETE', '/podcasts/${sub['id']}');
    // Sign out, so the test leaves no session "Linux (Test)" behind.
    await api.call('POST', '/auth/logout');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
