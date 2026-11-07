// Data types of the audiojoe API.

import 'dart:io';

class Quality {
  final String codec;
  final int? sampleRate, bitDepth, bitrate, channels;
  const Quality({this.codec = '', this.sampleRate, this.bitDepth, this.bitrate, this.channels});

  static Quality? fromJson(dynamic j) => j is Map
      ? Quality(
          codec: (j['codec'] ?? '') as String,
          sampleRate: j['sample_rate'] as int?,
          bitDepth: j['bit_depth'] as int?,
          bitrate: j['bitrate'] as int?,
          channels: j['channels'] as int?)
      : null;

  Map<String, dynamic> toJson() =>
      {'codec': codec, 'sample_rate': sampleRate, 'bit_depth': bitDepth, 'bitrate': bitrate, 'channels': channels};

  String get _codec => codec.startsWith('pcm_') ? 'PCM' : codec.toUpperCase();
  bool get _lossless => codec == 'flac' || codec == 'alac' || codec.startsWith('pcm_');

  /// Codec label of the chips ("FLAC", "PCM", "MP3").
  String get codecLabel => _codec;

  /// Lossless level for the codec chip: 'hi' from 24 bit (red), 'cd' at 16 bit (yellow), else null.
  String? get tier => !_lossless || bitDepth == null ? null : bitDepth! >= 24 ? 'hi' : bitDepth == 16 ? 'cd' : null;

  String get _rate => '${(sampleRate! / 1000).toStringAsFixed(sampleRate! % 1000 == 0 ? 0 : 1)} kHz';

  /// Separate facts for chips: ["24 Bit", "FLAC", "96 kHz", "Stereo"].
  List<String> get chips {
    if (codec.isEmpty) return const [];
    return [
      if (bitDepth != null) '$bitDepth Bit',
      _codec,
      if (sampleRate != null) _rate,
      if (bitrate != null && !_lossless) '${(bitrate! / 1000).round()} kbit/s',
      if (channels == 1) 'Mono' else if (channels == 2) 'Stereo' else if (channels != null) '$channels ch',
    ];
  }

  /// What a Sonos speaker receives (the server's rules in media::conversion).
  Quality forSonos(bool s2) {
    final rate = sampleRate ?? 0, depth = bitDepth ?? 16;
    if (s2 && codec == 'flac' && rate > 48000) {
      return Quality(codec: 'flac', sampleRate: 48000, bitDepth: depth > 24 ? 24 : depth, channels: channels);
    }
    if (!s2 && _lossless && (rate > 48000 || depth > 16)) {
      return Quality(codec: 'flac', sampleRate: rate > 48000 ? 48000 : rate, bitDepth: 16, channels: channels);
    }
    return this;
  }

  bool sameAs(Quality o) => codec == o.codec && sampleRate == o.sampleRate && bitDepth == o.bitDepth;

  /// "FLAC · 24 bit · 96 kHz · 3450 kbit/s"
  String get text {
    if (codec.isEmpty) return '–';
    final p = [_codec];
    if (bitDepth != null) p.add('$bitDepth bit');
    if (sampleRate != null) p.add(_rate);
    if (bitrate != null) p.add('${(bitrate! / 1000).round()} kbit/s');
    return p.join(' · ');
  }

  /// "FLAC 24/96"
  String get badge {
    if (codec.isEmpty) return '';
    if (bitDepth != null && sampleRate != null) return '$_codec $bitDepth/${(sampleRate! / 1000).round()}';
    if (bitrate != null) return '$_codec ${(bitrate! / 1000).round()}k';
    return _codec;
  }
}

class Part {
  final int index, startMs, durationMs;
  const Part(this.index, this.startMs, this.durationMs);
  static Part fromJson(dynamic j) => Part(j['index'] as int, j['start_ms'] as int, j['duration_ms'] as int);
  Map<String, dynamic> toJson() => {'index': index, 'start_ms': startMs, 'duration_ms': durationMs};
}

class Chapter {
  final String title;
  final int startMs, endMs;
  const Chapter(this.title, this.startMs, this.endMs);
  static Chapter fromJson(dynamic j) => Chapter(j['title'] as String, j['start_ms'] as int, j['end_ms'] as int);
  Map<String, dynamic> toJson() => {'title': title, 'start_ms': startMs, 'end_ms': endMs};
}

class Item {
  final String key, kind, title, subtitle;
  final int? durationMs, track, year;
  final String? image, published, description, notes, series;
  /// Music: key of the album a title belongs to (the cache pill saves the whole album).
  final String? album;
  final List<String> genres;
  final Quality? quality;
  final List<Part> parts;
  final List<Chapter> chapters;
  final int? positionMs;
  final bool finished, favorite;
  final Playback? playback;

  const Item({
    required this.key,
    required this.kind,
    required this.title,
    this.subtitle = '',
    this.durationMs,
    this.track,
    this.year,
    this.image,
    this.published,
    this.description,
    this.notes,
    this.series,
    this.album,
    this.genres = const [],
    this.quality,
    this.parts = const [],
    this.chapters = const [],
    this.positionMs,
    this.finished = false,
    this.favorite = false,
    this.playback,
  });

  static Item fromJson(Map<String, dynamic> j) => Item(
        key: j['key'] as String,
        kind: (j['kind'] ?? (j['key'].toString().startsWith('episode:') ? 'episode' : 'track')) as String,
        title: (j['title'] ?? '') as String,
        subtitle: (j['subtitle'] ?? j['podcast'] ?? '') as String,
        durationMs: j['duration_ms'] as int?,
        track: j['track'] as int?,
        year: j['year'] as int?,
        image: j['image'] as String?,
        published: j['published']?.toString(),
        description: j['description'] as String?,
        notes: j['notes'] as String?,
        series: j['series'] as String?,
        album: j['album'] as String?,
        genres: (j['genres'] as List? ?? []).map((g) => '$g').toList(),
        quality: Quality.fromJson(j['quality']),
        parts: (j['parts'] as List? ?? []).map(Part.fromJson).toList(),
        chapters: (j['chapters'] as List? ?? []).map(Chapter.fromJson).toList(),
        positionMs: j['position_ms'] as int?,
        finished: (j['finished'] ?? false) as bool,
        favorite: (j['favorite'] ?? false) as bool,
        playback: j['playback'] is Map ? Playback.fromJson(j['playback'] as Map<String, dynamic>, key: j['key'] as String) : null,
      );

  Map<String, dynamic> toJson() => {
        'key': key,
        'kind': kind,
        'title': title,
        'subtitle': subtitle,
        'duration_ms': durationMs,
        'track': track,
        'year': year,
        'image': image,
        'published': published,
        'description': description,
        'notes': notes,
        'album': album,
        'quality': quality?.toJson(),
        'parts': parts.map((p) => p.toJson()).toList(),
        'chapters': chapters.map((c) => c.toJson()).toList(),
      };

  bool get multiPart => parts.length > 1;
}

class Playback {
  final String key, title, subtitle, device, updatedAt;
  final int positionMs;
  final int? durationMs;
  final bool finished;
  /// The reporting device's state (playing | paused | stopped); sent, not stored per item.
  final String? state;

  const Playback({
    required this.key,
    required this.positionMs,
    this.durationMs,
    this.finished = false,
    this.title = '',
    this.subtitle = '',
    this.device = '',
    required this.updatedAt,
    this.state,
  });

  static Playback fromJson(Map<String, dynamic> j, {String? key}) => Playback(
        key: (j['key'] ?? key ?? '') as String,
        positionMs: j['position_ms'] as int,
        durationMs: j['duration_ms'] as int?,
        finished: (j['finished'] ?? false) as bool,
        title: (j['title'] ?? '') as String,
        subtitle: (j['subtitle'] ?? '') as String,
        device: (j['device'] ?? '') as String,
        updatedAt: j['updated_at'] as String,
      );

  Map<String, dynamic> toJson() => {
        'key': key,
        'position_ms': positionMs,
        'duration_ms': durationMs,
        'finished': finished,
        'title': title,
        'subtitle': subtitle,
        'device': device,
        'updated_at': updatedAt,
        if (state != null) 'state': state,
        if (state != null) 'kind': deviceKind,
      };
}

/// This app's kind in the server's device list.
String get deviceKind => Platform.isWindows
    ? 'windows'
    : Platform.isAndroid
        ? 'android'
        : 'linux';

/// A device of the account as listed by the server (`GET /devices`, event `device`).
class Device {
  final String name, kind, state, key, title, subtitle, updatedAt;
  final String? lastSeen;
  /// Name given in the settings ("Rename"); `name` stays the device's key.
  final String? label;
  final int positionMs;
  final int? durationMs;
  final bool online, current;

  const Device({required this.name, required this.kind, required this.state, required this.key, required this.title,
      required this.subtitle, required this.updatedAt, this.lastSeen, required this.positionMs, this.durationMs,
      required this.online, this.current = false, this.label});

  static Device fromJson(Map j) => Device(
        name: j['device'] as String,
        kind: (j['kind'] ?? '') as String,
        state: (j['state'] ?? 'stopped') as String,
        key: (j['key'] ?? '') as String,
        title: (j['title'] ?? '') as String,
        subtitle: (j['subtitle'] ?? '') as String,
        updatedAt: (j['updated_at'] ?? '') as String,
        lastSeen: j['last_seen'] as String?,
        positionMs: (j['position_ms'] ?? 0) as int,
        durationMs: j['duration_ms'] as int?,
        online: (j['online'] ?? false) as bool,
        current: (j['current'] ?? false) as bool,
        label: j['label'] as String?,
      );

  /// What the user sees: the given name, else the device name.
  String get shown => label ?? name;

  bool get playing => state == 'playing';
  bool get web => kind == 'web';
  bool get speaker => kind == 'sonos';
}
