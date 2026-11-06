library just_audio_media_kit;

import 'package:media_kit/media_kit.dart';

Future<void> setProperty(Player player, String key, dynamic value) async {
  if (player.platform is! NativePlayer) return;
  await (player.platform as NativePlayer).setProperty(key, value);
}

/// audiojoe: appends one entry to an mpv key-value list option (mpv command `change-list`); the
/// `-append` option suffix is not available through the property interface.
Future<void> appendToList(Player player, String key, String value) async {
  if (player.platform is! NativePlayer) return;
  await (player.platform as NativePlayer).command(['change-list', key, 'append', value]);
}
