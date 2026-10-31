// Unit tests for formatting and data types (no server needed).

import 'package:audiojoe/l10n.dart';
import 'package:audiojoe/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('clock', () {
    expect(clock(0), '0:00');
    expect(clock(842000), '14:02');
    expect(clock(3723000), '1:02:03');
  });

  test('quality text and badge', () {
    const q = Quality(codec: 'flac', bitDepth: 24, sampleRate: 96000, bitrate: 3450000);
    expect(q.text, 'FLAC · 24 bit · 96 kHz · 3450 kbit/s');
    expect(q.badge, 'FLAC 24/96');
    expect(const Quality(codec: 'mp3', bitrate: 128000).badge, 'MP3 128k');
    expect(const Quality(codec: 'pcm_s16le', bitDepth: 16, sampleRate: 44100).badge, 'PCM 16/44');
  });

  test('item round trip with parts and chapters', () {
    final it = Item.fromJson({
      'key': 'abs:1:x', 'kind': 'book', 'title': 'T', 'subtitle': 'A', 'duration_ms': 1000,
      'parts': [{'index': 0, 'start_ms': 0, 'duration_ms': 500}, {'index': 1, 'start_ms': 500, 'duration_ms': 500}],
      'chapters': [{'title': 'C1', 'start_ms': 0, 'end_ms': 1000}],
    });
    final back = Item.fromJson(it.toJson());
    expect(back.multiPart, isTrue);
    expect(back.parts[1].startMs, 500);
    expect(back.chapters.single.title, 'C1');
  });

  test('episode keys default to kind episode', () {
    expect(Item.fromJson({'key': 'episode:4', 'title': 'x', 'podcast': 'P'}).kind, 'episode');
    expect(Item.fromJson({'key': 'episode:4', 'title': 'x', 'podcast': 'P'}).subtitle, 'P');
  });
}
