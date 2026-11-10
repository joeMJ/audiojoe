// Settings → Quality (0.3.0, user 2026-11-10 „155“, „159“–„161“, „167“, „169“–„171“): what plays now and
// what this device can do; on Android the switch "Bit-perfect over USB" and the lowering of the volume.
// The switches belong to this device (Stores.device), not to the account.

import 'dart:async';
import 'dart:convert';
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

  /// Tells the Android player about the title it loads next (only music goes bit-perfect).
  Future<void> apply(Item? it) async {
    _current = it;
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
}

final qualityPrefs = QualityPrefs.instance;

const _channel = MethodChannel('com.ryanheise.just_audio.audiojoe');

/// Log of the bit-perfect path into Settings → Maintenance → Error log (test build for the Pixel,
/// user 2026-11-10: „Generiere APK mit Logfunktion“).
void bitPerfectLog(String message, [StackTrace? stack]) => errorLog.record('Bit-perfect: $message', stack);

/// Diagnostics as one line for the log.
String diagnosticsText(Map? a) {
  try {
    return jsonEncode(a);
  } catch (_) {
    return '$a';
  }
}

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
