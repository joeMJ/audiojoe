# Adapted copy of just_audio_media_kit 2.1.0

Source: https://pub.dev/packages/just_audio_media_kit/versions/2.1.0
(https://github.com/Pato05/just_audio_media_kit), licence: Unlicense (see `LICENSE`).
Used through `dependency_overrides` in `clients/app/pubspec.yaml`.

Change (marked `audiojoe:`): `lib/mediakit_player.dart` appends `fflags=+fastseek` to the
mpv option `demuxer-lavf-o` for every player (mpv command `change-list … append`, helper `appendToList` in `lib/src/set_property_*.dart`; media_kit sets other values
there itself, so the list must not be replaced). Without it libmpv reads an MP3 without a seek
index (no Xing/Info table, e.g. podcasts with inserted ads or one-file audiobooks) from the start up
to the position, so playing from a late position stays silent for a long time.
The compile-time switch `AUDIOJOE_NO_FASTSEEK=true` leaves the option out (counter-test only).

Updating: copy the new version over this folder (without `example/` and `test/`), put the marked
change back in, run `tools/third-party.py`.
