library just_audio_media_kit;

import 'package:media_kit/media_kit.dart';

Future<void> setProperty(Player player, String key, dynamic value) {
  // noop
  return Future.value();
}

/// audiojoe: see set_property_io.dart.
Future<void> appendToList(Player player, String key, String value) => Future.value();
