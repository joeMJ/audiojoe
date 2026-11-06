// Linux/Windows: plays an MP3 without a seek index from a late position for a few seconds and prints
// when play() was called. The position alone proves nothing: just_audio counts it up while playing,
// also while libmpv still reads the file up to the position and nothing is heard (Lage der Nation 501,
// 2026-11-05).
//
// Two measurements:
// - tools/dev/fastseek-test-linux.sh records the sound card and measures the silence (Linux).
// - Without a sound card (Windows VM): libmpv reports "playback restart complete @ <pts>" once the jump
//   to the position is done and decoding goes on. The time from play() to that line (at the start
//   position) is printed as "FASTSEEK restart after … ms"; checked against the recording on Linux.
//
//   flutter test integration_test/fastseek_test.dart -d linux|windows --dart-define=START=3600
//       [--dart-define=URL=…] [--dart-define=PLAY=40] [--dart-define=MAX_MS=8000]
//       [--dart-define=AUDIOJOE_NO_FASTSEEK=true] [--dart-define=AUDIOJOE_AO=null]
// Without any audio device libmpv stops at once ("no sound", audio=eof; Windows VM 2026-11-06):
// AUDIOJOE_AO=null uses libmpv's null output, which plays in real time without a device.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
// ignore: depend_on_referenced_packages
import 'package:media_kit/media_kit.dart' show MPVLogLevel;

const url = String.fromEnvironment('URL',
    defaultValue: 'https://dts.podtrac.com/redirect.mp3/files.lagedernation.org/lagedernation/LdN501.mp3');
const seconds = int.fromEnvironment('START', defaultValue: 3600);
const playFor = int.fromEnvironment('PLAY', defaultValue: 40);
// Longest accepted time from play() to the restart at the start position (Linux 2026-11-06: 0.5 s with,
// 16.9 s without fastseek; the recording showed 0.0 s and 15.1 s of silence).
const maxMs = int.fromEnvironment('MAX_MS', defaultValue: 8000);

final _restart = RegExp(r'playback restart complete @ (-?[0-9.]+)(.*)');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Verbose: "playback restart complete" is logged at level v.
  JustAudioMediaKit.mpvLogLevel = MPVLogLevel.v;
  JustAudioMediaKit.ensureInitialized(linux: true, windows: true);

  testWidgets('play from a late position', (tester) async {
    int? playAt;
    int? restartMs;
    // The player prints libmpv's log lines ("MPV: [level] prefix: text"); catch them with a time.
    final spec = ZoneSpecification(print: (self, parent, zone, line) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final m = _restart.firstMatch(line);
      if (m != null) {
        final pts = double.tryParse(m.group(1)!) ?? -1;
        final rel = playAt == null ? 'before play()' : '${now - playAt!} ms after play()';
        parent.print(zone, 'FASTSEEK mpv restart @ ${pts.toStringAsFixed(1)} s, $rel${m.group(2)}');
        if (playAt != null && restartMs == null && pts >= seconds - 1) restartMs = now - playAt!;
        return;
      }
      // Keep the verbose lines out of the test log, warnings and errors stay.
      if (line.startsWith('MPV: [v]') || line.startsWith('MPV: [info]')) return;
      parent.print(zone, line);
    });
    await tester.runAsync(() => runZoned(() async {
          final player = AudioPlayer();
          await player.setAudioSources([AudioSource.uri(Uri.parse(url))],
              initialPosition: const Duration(seconds: seconds));
          playAt = DateTime.now().millisecondsSinceEpoch;
          // ignore: avoid_print
          print('FASTSEEK play at $playAt');
          player.play();
          await Future<void>.delayed(const Duration(seconds: playFor));
          // ignore: avoid_print
          print('FASTSEEK position ${player.position}');
          // A restart at the start position before play() means the jump was done while paused: no wait.
          // ignore: avoid_print
          print(restartMs == null
              ? 'FASTSEEK restart after play(): none at the start position'
              : 'FASTSEEK restart after $restartMs ms');
          await player.dispose();
        }, zoneSpecification: spec));
    expect(restartMs, isNotNull, reason: 'libmpv did not reach the start position');
    expect(restartMs, lessThanOrEqualTo(maxMs), reason: 'jump to the start position took too long');
  });
}
