// Notification and lock-screen controls on Android (audio_service): play/pause, seeking in
// the whole item, and ⏮ ⏭ by chapter – by title when there are none.

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import 'api.dart';
import 'player.dart';

class _Handler extends BaseAudioHandler with SeekHandler {
  _Handler() {
    player.addListener(_update);
    player.audio.playbackEventStream.listen((_) => _update(), onError: (_) {});
  }

  String _shown = '';

  void _update() {
    final it = player.item;
    if (it == null) {
      playbackState.add(playbackState.value.copyWith(processingState: AudioProcessingState.idle, playing: false));
      return;
    }
    final line = player.chapterLine;
    final dur = player.duration;
    final id = '${it.key}|$line|$dur';
    // Title, chapter and length only when they change: each update redraws the notification.
    if (id != _shown) {
      _shown = id;
      mediaItem.add(MediaItem(
        id: it.key,
        title: it.title,
        artist: line.isNotEmpty ? line : it.subtitle,
        album: it.subtitle,
        duration: dur > 0 ? Duration(milliseconds: dur) : null,
        artUri: it.image == null ? null : api.imageUri(it.image!),
        artHeaders: api.authHeaders,
      ));
    }
    final playing = player.playing;
    final steps = player.chapters.isNotEmpty || player.queue.length > 1;
    final controls = [
      if (steps) MediaControl.skipToPrevious,
      if (!player.live) MediaControl.rewind,
      playing ? MediaControl.pause : MediaControl.play,
      if (!player.live) MediaControl.fastForward,
      if (steps) MediaControl.skipToNext,
    ];
    final state = switch (player.audio.processingState) {
      ProcessingState.idle => AudioProcessingState.idle,
      ProcessingState.loading => AudioProcessingState.loading,
      ProcessingState.buffering => AudioProcessingState.buffering,
      ProcessingState.ready => AudioProcessingState.ready,
      ProcessingState.completed => AudioProcessingState.completed,
    };
    // The system moves the position on by itself: send it again only after a jump.
    final last = playbackState.value;
    final pos = Duration(milliseconds: player.position);
    final drift = (last.position - pos).inMilliseconds.abs();
    final sig = '${controls.map((c) => c.action.name).join(',')}|$playing|$state|${player.rate}';
    if (sig == _sig && drift < 1500) return;
    _sig = sig;
    playbackState.add(PlaybackState(
      controls: controls,
      systemActions: {if (!player.live) MediaAction.seek, MediaAction.playPause},
      // Small notification: ⏮ ⏯ ⏭, or ⏪ ⏯ ⏩ without chapters.
      androidCompactActionIndices: [
        for (final a in steps ? [MediaAction.skipToPrevious, playing ? MediaAction.pause : MediaAction.play, MediaAction.skipToNext]
            : [MediaAction.rewind, playing ? MediaAction.pause : MediaAction.play, MediaAction.fastForward])
          if (controls.indexWhere((c) => c.action == a) >= 0) controls.indexWhere((c) => c.action == a),
      ],
      processingState: state,
      playing: playing,
      updatePosition: pos,
      bufferedPosition: pos,
      speed: player.rate,
    ));
  }

  String _sig = '';

  @override
  Future<void> play() async => player.playing ? null : player.toggle();
  @override
  Future<void> pause() async => player.playing ? player.toggle() : null;
  @override
  Future<void> stop() => player.stop();
  @override
  Future<void> seek(Duration position) => player.seekTo(position.inMilliseconds);
  @override
  Future<void> rewind() => player.seekBy(-15000);
  @override
  Future<void> fastForward() => player.seekBy(30000);
  @override
  Future<void> skipToNext() => player.chapters.isNotEmpty ? player.nextChapter() : player.skip(1);
  @override
  Future<void> skipToPrevious() => player.chapters.isNotEmpty ? player.previousChapter() : player.skip(-1);
}

Future<void> startMediaSession() async {
  await AudioService.init(
    builder: _Handler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'io.github.joemj.audiojoe.playback',
      androidNotificationChannelName: 'Playback',
      androidNotificationOngoing: true,
      fastForwardInterval: Duration(seconds: 30),
      rewindInterval: Duration(seconds: 15),
    ),
  );
}
