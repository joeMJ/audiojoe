// Quitting while a title plays (user 2026-11-09: "ich hatte aj auf diesem Rechner während des
// spielens beendet" – Ubuntu reported a crash; 0.2.4: SIGSEGV in a libmpv thread). The test plays
// a title and closes the window as the title bar's close button does; the app process must end
// without a signal. tools/dev/quit-test-linux.sh runs it under strace and checks that, and that the
// server got the position as "paused" (the app saves it before it ends).
//
//   flutter test integration_test/quit_test.dart -d linux --dart-define=SERVER=… --dart-define=USER=…
//     --dart-define=PASS=… --dart-define=TOTP_SECRET=… --dart-define=SEARCH=<album name>

import 'package:audiojoe/api.dart';
import 'package:audiojoe/main.dart' as app;
import 'package:audiojoe/models.dart';
import 'package:audiojoe/player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:window_manager/window_manager.dart';

import 'app_test.dart' show totp, waitFor, waitUntil;

const server = String.fromEnvironment('SERVER');
const user = String.fromEnvironment('USER');
const pass = String.fromEnvironment('PASS');
const secret = String.fromEnvironment('TOTP_SECRET');
const search = String.fromEnvironment('SEARCH', defaultValue: 'Anjunabeats');

// ignore: avoid_print
void log(String s) => print('${DateTime.now().toIso8601String().substring(11, 19)} $s');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('quit while playing: no crash, position saved', (tester) async {
    await app.main();
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await Future.delayed(Duration(seconds: 31 - DateTime.now().second % 30));
    await tester.enterText(fields.at(0), server);
    await tester.enterText(fields.at(1), user);
    await tester.enterText(fields.at(2), pass);
    await tester.enterText(fields.at(3), totp(secret, DateTime.now()));
    await tester.enterText(fields.at(4), 'Linux (Test)');
    await tester.tap(find.byType(FilledButton));
    await waitFor(tester, find.byTooltip('Server reachable'));

    final sources = (await api.call('GET', '/sources') as List).cast<Map>().where((s) => s['kind'] == 'jellyfin');
    final src = sources.first['id'];
    final found = await api.call('GET', '/sources/$src/browse', query: {'search': search, 'limit': '50'}) as Map;
    final album = [for (final j in found['items'] as List) Item.fromJson((j as Map).cast<String, dynamic>())].firstWhere((i) => i.kind == 'album');
    final res = await api.call('GET', '/sources/$src/browse', query: {'parent': album.key.split(':')[2], 'limit': '500'}) as Map;
    final tracks = [for (final j in res['items'] as List) Item.fromJson((j as Map).cast<String, dynamic>())].where((i) => i.kind == 'track').toList();

    await player.play(tracks, 1, (list: 'music', key: album.key));
    await waitUntil(tester, () => player.audio.playing, seconds: 20, what: 'title 2 playing');
    await tester.pump(const Duration(seconds: 8));
    log('PLAYING ${tracks[1].key} at ${player.position ~/ 1000} s, device ${api.device}');
    log('CLOSING');
    // As the title bar's close button.
    await windowManager.close();
    // The process ends here; reaching the end means the window did not close.
    await tester.pump(const Duration(seconds: 20));
    log('STILL RUNNING');
    fail('the window did not close');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
