// Linux/Windows: plays an MP3 without a seek index from a late position for a few seconds and prints
// when play() was called. The position alone proves nothing: just_audio counts it up while playing,
// also while libmpv still reads the file up to the position and nothing is heard (Lage der Nation 501,
// 2026-11-05). tools/dev/fastseek-test-linux.sh records the sound card and measures the silence.
//
//   flutter test integration_test/fastseek_test.dart -d linux --dart-define=START=3600 [--dart-define=URL=…]

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

const url = String.fromEnvironment('URL',
    defaultValue: 'https://dts.podtrac.com/redirect.mp3/files.lagedernation.org/lagedernation/LdN501.mp3');
const seconds = int.fromEnvironment('START', defaultValue: 3600);
const playFor = int.fromEnvironment('PLAY', defaultValue: 40);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  JustAudioMediaKit.ensureInitialized(linux: true, windows: true);

  testWidgets('play from a late position', (tester) async {
    final player = AudioPlayer();
    await tester.runAsync(() async {
      await player.setAudioSources([AudioSource.uri(Uri.parse(url))], initialPosition: const Duration(seconds: seconds));
      // ignore: avoid_print
      print('FASTSEEK play at ${DateTime.now().millisecondsSinceEpoch}');
      player.play();
      await Future<void>.delayed(const Duration(seconds: playFor));
      // ignore: avoid_print
      print('FASTSEEK position ${player.position}');
      await player.dispose();
    });
  });
}
