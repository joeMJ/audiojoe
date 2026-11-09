# Adapted copy of just_audio 0.10.6

Source: https://pub.dev/packages/just_audio/versions/0.10.6
(https://github.com/ryanheise/just_audio), licence: MIT (see `LICENSE`). The folders `example` and
`test` of the package are left out. Used through `dependency_overrides` in `clients/app/pubspec.yaml`.

Change (marked `audiojoe:`), Android only: `android/src/main/java/com/ryanheise/just_audio/AudioPlayer.java`,
`ensurePlayerInitialized()`: the `DefaultRenderersFactory` gets
`setEnableAudioFloatOutput(true)` and `setEnableAudioTrackPlaybackParams(true)`.

Why (user 2026-11-09: "24 Bit MUSS definitiv möglich sein, ohne downsampling nach 16 Bit"): without float
output Media3 1.4.1 (`DefaultAudioSink`, `ToInt16PcmAudioProcessor`) converts every PCM format to 16 bit,
and `MediaCodecAudioRenderer` asks the FLAC decoder for 16 bit. With float output the decoder delivers
32-bit float, which holds 24-bit samples exactly. Float output bypasses Sonic (the speed processor works
on 16 bit only), so the speed of podcasts and audiobooks is set on the AudioTrack instead.
