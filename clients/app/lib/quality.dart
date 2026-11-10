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
    if (Platform.isLinux || Platform.isWindows) return _applyDesktop(it);
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

  // ---------------------------------------------------------------- Linux, Windows

  /// The DAC libmpv plays on directly, null: the system mixer ("auto").
  UsbDac? desktopDac;
  int _watch = 0;

  /// How often and how far apart a DAC still held by another program is tried again (PipeWire releases an
  /// idle device after about 5 s).
  static Duration retryEvery = const Duration(seconds: 2);
  static int retries = 4;

  Future<void> _applyDesktop(Item? it) async {
    UsbDac? dac;
    if (bitPerfect && it?.kind == 'track') {
      final rate = it?.quality?.sampleRate;
      for (final d in await usbDacs()) {
        // Only at a rate the DAC takes itself (Linux knows them; Windows: WASAPI decides).
        if (rate == null || d.rates.isEmpty || d.rates.contains(rate)) {
          dac = d;
          break;
        }
      }
    }
    desktopDac = dac;
    final watch = ++_watch;
    try {
      await mk.audiojoeSetAudioDevice(dac?.device ?? 'auto', exclusive: dac?.exclusive ?? false);
    } catch (e, s) {
      bitPerfectLog('audio device failed: $e', s);
    }
    notifyListeners();
    if (dac != null) unawaited(_watchDesktop(dac, watch));
  }

  /// libmpv cannot open the DAC while another program holds it (PipeWire on Linux, an exclusive program on
  /// Windows): it decodes but outputs nothing. Try again a few times, then play through the system mixer
  /// and note it in the error log.
  Future<void> _watchDesktop(UsbDac dac, int watch) async {
    var silent = 0;
    for (var i = 0; i < retries * 2 + 2; i++) {
      await Future<void>.delayed(retryEvery);
      if (watch != _watch) return;
      final o = await mk.audiojoeOutputInfo();
      if (o['audio-device'] != dac.device) {
        // A new player of just_audio that did not get the device yet.
        await mk.audiojoeSetAudioDevice(dac.device, exclusive: dac.exclusive);
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
    bitPerfectLog('${dac.name} is in use by another program; the title plays through the system mixer');
    desktopDac = null;
    await mk.audiojoeSetAudioDevice('auto');
    notifyListeners();
  }
}

final qualityPrefs = QualityPrefs.instance;

/// A USB DAC libmpv can play on directly.
abstract class UsbDac {
  String get name;

  /// libmpv's audio device ("alsa/hw:…" or "wasapi/{…}").
  String get device;

  /// Whether the device needs the exclusive mode (WASAPI).
  bool get exclusive;

  /// Rates the DAC takes; empty: not known (Windows).
  List<int> get rates;

  /// Bit depth of the DAC; 0: not known (Windows).
  int get bits;
}

/// A USB DAC as ALSA lists it (/proc/asound): card id, name and its playback formats.
class AlsaCard implements UsbDac {
  final String id;
  @override
  final String name;
  @override
  final List<int> rates;
  @override
  final int bits;
  final int channels;
  const AlsaCard(this.id, this.name, this.rates, this.bits, this.channels);

  /// libmpv's device for the card itself, without dmix or PipeWire.
  @override
  String get device => 'alsa/hw:CARD=$id,DEV=0';
  @override
  bool get exclusive => false;
}

/// A USB DAC on Windows: a WASAPI device of libmpv whose name is that of a USB sound device.
class WasapiDac implements UsbDac {
  @override
  final String name, device;
  const WasapiDac(this.name, this.device);
  @override
  bool get exclusive => true;
  @override
  List<int> get rates => const [];
  @override
  int get bits => 0;
}

/// The USB DACs of this computer (Linux: ALSA; Windows: WASAPI devices of USB sound devices).
Future<List<UsbDac>> usbDacs() async => Platform.isLinux ? await alsaUsbCards() : Platform.isWindows ? await wasapiUsbDacs() : const [];

/// Names of the USB sound devices (Win32_SoundDevice with a USB PnP id), read once per [usbNamesFor].
List<String>? _usbNames;
DateTime? _usbNamesAt;
@visibleForTesting
Duration usbNamesFor = const Duration(seconds: 30);

/// Windows: libmpv's WASAPI devices whose description names a USB sound device, e.g.
/// "Lautsprecher (Scarlett Solo 4th Gen)" for the USB device "Scarlett Solo 4th Gen".
Future<List<UsbDac>> wasapiUsbDacs() async {
  final now = DateTime.now();
  if (_usbNames == null || _usbNamesAt == null || now.difference(_usbNamesAt!) > usbNamesFor) {
    try {
      final r = await Process.run('powershell', [
        '-NoProfile', '-NonInteractive', '-Command',
        r"Get-CimInstance Win32_SoundDevice | Where-Object { $_.PNPDeviceID -like 'USB*' } | ForEach-Object { $_.Name }",
      ]);
      _usbNames = ('${r.stdout}').split(RegExp(r'\r?\n')).map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
      _usbNamesAt = now;
    } catch (e, s) {
      bitPerfectLog('USB sound devices not readable: $e', s);
      _usbNames = const [];
      _usbNamesAt = now;
    }
  }
  return matchWasapi(_usbNames!, await mk.audiojoeAudioDevices());
}

/// The WASAPI devices of libmpv whose description contains one of the USB names.
@visibleForTesting
List<UsbDac> matchWasapi(List<String> usbNames, List<Map<String, String>> devices) => [
      for (final d in devices)
        if ((d['name'] ?? '').startsWith('wasapi/'))
          for (final n in usbNames)
            if ((d['description'] ?? '').toLowerCase().contains(n.toLowerCase())) WasapiDac(n, d['name']!),
    ];

/// "Windows 10 Pro (Build 19045)" from the system.
String windowsName() => Platform.operatingSystemVersion.replaceAll('"', '');

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
