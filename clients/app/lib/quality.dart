// Settings → Quality (0.3.0, user 2026-11-10 „155“, „159“–„161“, „167“, „169“–„171“): what plays now and
// what this device can do; on Android the switch "Bit-perfect over USB" and the lowering of the volume.
// Linux („185 konfigurierbar, ja“): the same switch; music then goes from libmpv straight to the USB DAC
// (ALSA "hw:", past PipeWire, which resamples everything to its own rate). The switches belong to this
// device (Stores.device), not to the account.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart' as mk;

import 'errors.dart';
import 'l10n.dart';
import 'main.dart' show messenger;
import 'models.dart';
import 'store.dart';

class QualityPrefs extends ChangeNotifier {
  QualityPrefs._() {
    final Object? v = Stores.device.get('quality');
    if (v is Map) {
      bitPerfect = v['bit_perfect'] == true;
      lower = v['lower'] != false;
    }
  }
  static final instance = QualityPrefs._();

  /// Android: music goes unchanged to a USB DAC that the device offers bit-perfect for.
  bool bitPerfect = false;

  /// Android: before bit-perfect playback after connecting, the media volume goes down to 20 %.
  bool lower = true;

  Future<void> set({bool? bitPerfect, bool? lower}) async {
    this.bitPerfect = bitPerfect ?? this.bitPerfect;
    this.lower = lower ?? this.lower;
    Stores.device.put('quality', {'bit_perfect': this.bitPerfect, 'lower': this.lower});
    notifyListeners();
    await apply(_current);
  }

  Item? _current;

  /// Tells the player about the title it loads next (only music goes bit-perfect).
  Future<void> apply(Item? it) async {
    _current = it;
    if (Platform.isLinux) return _applyLinux(it);
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('set', {
        'enabled': bitPerfect,
        'music': it?.kind == 'track',
        'lower': lower,
        'bits': it?.quality?.bitDepth ?? 0,
      });
    } catch (e, s) {
      bitPerfectLog('set failed: $e', s);
    }
  }

  // ---------------------------------------------------------------- Linux

  /// The DAC libmpv plays on directly, null: the system mixer ("auto").
  AlsaCard? linuxDevice;
  int _watch = 0;

  /// How often and how far apart a DAC still held by PipeWire is tried again (PipeWire releases an idle
  /// device after about 5 s).
  static Duration retryEvery = const Duration(seconds: 2);
  static int retries = 4;

  Future<void> _applyLinux(Item? it) async {
    AlsaCard? card;
    if (bitPerfect && it?.kind == 'track') {
      final rate = it?.quality?.sampleRate;
      for (final c in await alsaUsbCards()) {
        // Only at a rate the DAC takes itself; otherwise the system mixer converts as before.
        if (rate == null || c.rates.contains(rate)) {
          card = c;
          break;
        }
      }
    }
    linuxDevice = card;
    final watch = ++_watch;
    try {
      await mk.audiojoeSetAudioDevice(card?.device ?? 'auto');
    } catch (e, s) {
      bitPerfectLog('audio device failed: $e', s);
    }
    notifyListeners();
    if (card != null) unawaited(_watchLinux(card, watch));
  }

  /// libmpv cannot open the DAC while PipeWire still holds it ("device busy"): it decodes but outputs
  /// nothing. Try again a few times, then play through the system mixer and note it in the error log.
  Future<void> _watchLinux(AlsaCard card, int watch) async {
    var silent = 0;
    for (var i = 0; i < retries * 2 + 2; i++) {
      await Future<void>.delayed(retryEvery);
      if (watch != _watch) return;
      final o = await mk.audiojoeOutputInfo();
      if (o['audio-device'] != card.device) {
        // A new player of just_audio that did not get the device yet.
        await mk.audiojoeSetAudioDevice(card.device);
        continue;
      }
      if ((o['audio-params/samplerate'] ?? '').isEmpty) continue; // nothing decoded yet (loading, paused)
      if ((o['audio-out-params/samplerate'] ?? '').isNotEmpty) return; // the DAC plays
      // Decoding but no output: only after two checks in a row (no reload for a short gap at the start).
      if (++silent < 2) continue;
      if (silent - 1 > retries) break;
      await mk.audiojoeReloadAudioOutput();
    }
    if (watch != _watch) return;
    final o = await mk.audiojoeOutputInfo();
    if ((o['audio-params/samplerate'] ?? '').isEmpty || (o['audio-out-params/samplerate'] ?? '').isNotEmpty) return;
    bitPerfectLog('${card.name} is in use by another program; the title plays through the system mixer');
    linuxDevice = null;
    await mk.audiojoeSetAudioDevice('auto');
    notifyListeners();
  }
}

final qualityPrefs = QualityPrefs.instance;

/// A USB DAC as ALSA lists it (/proc/asound): card id, name and its playback formats.
class AlsaCard {
  final String id, name;
  final List<int> rates;
  final int bits, channels;
  const AlsaCard(this.id, this.name, this.rates, this.bits, this.channels);

  /// libmpv's device for the card itself, without dmix or PipeWire.
  String get device => 'alsa/hw:CARD=$id,DEV=0';
}

/// Root of /proc/asound (tests point it elsewhere).
@visibleForTesting
String asoundRoot = '/proc/asound';

/// The USB DACs with a playback stream ("USB-Audio" in /proc/asound/cards, formats from stream0).
Future<List<AlsaCard>> alsaUsbCards() async {
  final out = <AlsaCard>[];
  try {
    final cards = await File('$asoundRoot/cards').readAsLines();
    final head = RegExp(r'^\s*(\d+)\s+\[(\S+)\s*\]:\s*USB-Audio\s*-\s*(.+?)\s*$');
    for (final line in cards) {
      final m = head.firstMatch(line);
      if (m == null) continue;
      final f = File('$asoundRoot/card${m[1]}/stream0');
      if (!await f.exists()) continue;
      final text = await f.readAsString();
      final i = text.indexOf('Playback:');
      if (i < 0) continue;
      final end = text.indexOf('Capture:', i);
      final play = text.substring(i, end < 0 ? text.length : end);
      final rates = [for (final r in RegExp(r'Rates:\s*([0-9, ]+)').firstMatch(play)?[1]?.split(',') ?? const <String>[]) int.tryParse(r.trim()) ?? 0]
        ..removeWhere((r) => r <= 0);
      final bits = int.tryParse(RegExp(r'Bits:\s*(\d+)').firstMatch(play)?[1] ?? '') ?? 0;
      final ch = int.tryParse(RegExp(r'Channels:\s*(\d+)').firstMatch(play)?[1] ?? '') ?? 0;
      if (rates.isEmpty) continue;
      out.add(AlsaCard(m[2]!, m[3]!, rates, bits, ch));
    }
  } catch (_) {}
  return out;
}

/// "Ubuntu 26.04 LTS" from /etc/os-release.
Future<String> linuxName() async {
  try {
    for (final l in await File('/etc/os-release').readAsLines()) {
      if (l.startsWith('PRETTY_NAME=')) return l.substring(12).replaceAll('"', '');
    }
  } catch (_) {}
  return 'Linux';
}

const _channel = MethodChannel('com.ryanheise.just_audio.audiojoe');

/// Errors of the bit-perfect path into Settings → Maintenance → Error log (only errors, user 2026-11-10 „184“:
/// the lines of the Pixel test build are gone).
void bitPerfectLog(String message, [StackTrace? stack]) => errorLog.record('Bit-perfect: $message', stack);

/// Android reports that it lowered the volume before bit-perfect playback, and lines for the log.
void startQualityEvents() {
  if (!Platform.isAndroid) return;
  _channel.setMethodCallHandler((call) async {
    if (call.method == 'log') {
      bitPerfectLog('Android: ${call.arguments}');
      return null;
    }
    if (call.method == 'lowered') {
      messenger.currentState?.showSnackBar(SnackBar(content: Text(t('Volume lowered to 20 % for bit-perfect playback.'))));
    }
    return null;
  });
}

/// The facts of the Android player (BitPerfect.java): device, USB DAC, offered formats, last output.
Future<Map<String, dynamic>?> androidDiagnostics() async {
  if (!Platform.isAndroid) return null;
  try {
    return Map<String, dynamic>.from(await _channel.invokeMethod('diagnostics') as Map);
  } catch (_) {
    return null;
  }
}

/// Linux/Windows: what libmpv decodes and what it hands to the system ("audio-params", "audio-out-params").
Future<Map<String, String>> desktopOutput() async => Platform.isAndroid ? const {} : await mk.audiojoeOutputInfo();

/// "24 bit", "32-bit float" from the encoding names of BitPerfect.java.
String encodingText(Object? e) => switch ('$e') {
      'float' => '32-bit float',
      '16' || '24' || '32' => '$e bit',
      _ => '$e',
    };

String rateText(Object? r) {
  final v = r is int ? r : int.tryParse('$r') ?? 0;
  if (v <= 0) return '';
  return '${(v / 1000).toStringAsFixed(v % 1000 == 0 ? 0 : 1)} kHz';
}

/// "24 bit · 96 kHz · 2 ch" for one entry of the diagnostics.
String formatText(Map? m) {
  if (m == null) return '–';
  return [encodingText(m['encoding']), rateText(m['rate']), if (m['channels'] != null) '${m['channels']} ch']
      .where((s) => s.isNotEmpty)
      .join(' · ');
}

/// "24 bit, 32 bit · 44.1–192 kHz" for the formats offered over USB.
String offeredText(List offered) {
  if (offered.isEmpty) return '–';
  final enc = {for (final o in offered) encodingText((o as Map)['encoding'])}.toList();
  final rates = {for (final o in offered) (o as Map)['rate'] as int}.toList()..sort();
  final r = rates.length == 1 ? rateText(rates.first) : '${rateText(rates.first).replaceAll(' kHz', '')}–${rateText(rates.last)}';
  return '${enc.join(', ')} · $r';
}

bool offersBitPerfect(List offered) => offered.any((o) => (o as Map)['bitPerfect'] == true);
