# Adapted copy of just_audio 0.10.6 (with Media3 1.11.1 since audiojoe 0.3.0)

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

## 0.3.0: Media3 1.11.1 and bit-perfect over USB

User 2026-11-10 („164 - A Ja“): Media3 (`android/build.gradle.kts`, `exoplayerVersion`) goes from 1.4.1 to
1.11.1 (Google/AndroidX, Apache-2.0), because only from there the AudioTrack is built behind the interface
`AudioOutputProvider`. just_audio 0.10.6 builds with it unchanged.

New, Android only:
- `BitPerfect.java`: the audio sink of the player (`DefaultAudioSink` with float output, speed on the
  AudioTrack, this provider; hooked in through `DefaultRenderersFactory.buildAudioSink` in
  `AudioPlayer.java`). For music with the switch on (Settings → Quality, method channel
  `com.ryanheise.just_audio.audiojoe`) it looks for a USB output, asks Android for a mixer with behaviour
  `BIT_PERFECT` at the title's rate and channels (32-bit, else 24-bit packed, for sources up to 16 bit also
  16-bit integer), sets it with `setPreferredMixerAttributes` and opens the AudioTrack in exactly that
  encoding. Android attaches a track to the bit-perfect mixer only if encoding, channel mask and rate
  match. Otherwise, and for podcasts, audiobooks and radio, Media3's `AudioTrackAudioOutputProvider` as is.
- Towards Media3 the output stays float: `DefaultAudioSink` fades in the first 20 ms after a start or seek
  (`PcmAudioUtil.rampUpVolume`, reading the buffer in the encoding of the `OutputConfig`); with an integer
  encoding there it misreads the float samples (32 bit: a click, 24 bit: `BufferUnderflowException`, seen on
  the emulator). So `getOutputConfig` answers float and `getAudioOutput` opens the AudioTrack in the
  integer encoding behind `Converting`. Consequence: those 20 ms after start and seek are faded in, as on
  the normal path; everything after them reaches the DAC bit for bit.
- Before the first bit-perfect title after connecting a USB device the media volume goes down to 20 %
  (switchable, user „167“). In bit-perfect mode Android applies no software volume; the track's volume goes
  to the HAL (`BitPerfectThread::prepareTracks_l` → `setVolumeForOutput_l`), which in AOSP's USB HAL sets
  the DAC's own volume control (`StreamOutUsb::setHwVolume`). A DAC without one plays at full level.
- `PcmConvert.java`: Media3 delivers float; Android's FLAC decoder makes it `s << (32 - bits)` × 2^-31
  (`FLACDecoder.cpp` `copyToFloat`, `float_from_i32`), exact for 16 and 24 bit. Scaling back gives the
  samples bit for bit (checked for every 16- and 24-bit value: `tools/dev/pcmconvert-check/run.sh`).
- `adb shell setprop debug.audiojoe.int_output 32` (or 24, 16): integer output through the normal mixer
  without a USB DAC, for the emulator.
- `JustAudioPlugin.java`: `BitPerfect.init(...)`.
