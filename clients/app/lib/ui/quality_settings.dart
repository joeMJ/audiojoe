// Settings → Quality (0.3.0): "Now playing" on all apps, "This device" and the switches on Android.
// Texts: user 2026-11-10 „169 es passt, ja“; switch grey with the reason where not offered („160“);
// lowering on by default, turning it off only after the risk question („167“). Switching bit-perfect on shows
// the full-screen red warning (0.3.2, bit_perfect_warning.dart).

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../l10n.dart';
import '../player.dart';
import '../quality.dart';
import 'bit_perfect_warning.dart';
import 'common.dart';
import 'settings.dart' show SettingsGroup;

class QualitySettings extends StatefulWidget {
  const QualitySettings({super.key});

  /// "Bit-perfect over USB: on" for the overview (Android only).
  static String summary() => '${t('Bit-perfect over USB')}: ${qualityPrefs.bitPerfect ? t('on') : t('off')}';

  /// How often the page reads the player's facts again.
  static Duration every = const Duration(seconds: 2);

  @override
  State<QualitySettings> createState() => _QualitySettingsState();
}

class _QualitySettingsState extends State<QualitySettings> {
  Map<String, dynamic>? _android;
  Map<String, String> _desktop = const {};
  List<UsbDac> _dacs = const [];
  String _os = '';
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    qualityPrefs.addListener(_changed);
    player.addListener(_changed);
    unawaited(_read());
    _timer = Timer.periodic(QualitySettings.every, (_) => _read());
  }

  @override
  void dispose() {
    _timer?.cancel();
    qualityPrefs.removeListener(_changed);
    player.removeListener(_changed);
    super.dispose();
  }

  void _changed() => mounted ? setState(() {}) : null;

  Future<void> _read() async {
    final a = await androidDiagnostics();
    final d = await desktopOutput();
    final dacs = await usbDacs();
    final os = _os.isNotEmpty ? _os : Platform.isLinux ? await linuxName() : Platform.isWindows ? windowsName() : '';
    if (!mounted) return;
    setState(() {
      _android = a;
      _desktop = d;
      _dacs = dacs;
      _os = os;
    });
  }

  Widget _row(String label, String value, {Key? key}) {
    final k = context.tok;
    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 170, child: Text(label, style: TextStyle(color: k.muted))),
        Expanded(child: Text(value.isEmpty ? '–' : value, style: const TextStyle(fontWeight: FontWeight.w600))),
      ]),
    );
  }

  String get _source {
    final q = player.item?.quality;
    return q == null || q.codec.isEmpty ? '–' : q.chips.join(' · ');
  }

  /// Name and kind of the device the AudioTrack plays on (AudioDeviceInfo types).
  String _routed(Map? r) {
    if (r == null) return '–';
    final type = switch (r['type']) {
      11 || 22 => 'USB',
      8 || 26 || 27 => 'Bluetooth',
      _ => null,
    };
    return type == null ? '${r['name']}' : '${r['name']} ($type)';
  }

  /// libmpv: "s32 · 96 kHz · 2 ch (pipewire)".
  String get _mpvOut {
    final d = _desktop;
    final f = [d['audio-out-params/format'] ?? '', rateText(d['audio-out-params/samplerate']), if ((d['audio-out-params/channel-count'] ?? '').isNotEmpty) '${d['audio-out-params/channel-count']} ch']
        .where((s) => s.isNotEmpty)
        .join(' · ');
    final ao = d['current-ao'] ?? '';
    return f.isEmpty ? '' : ao.isEmpty ? f : '$f ($ao)';
  }

  @override
  Widget build(BuildContext context) {
    final a = _android;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SettingsGroup(title: t('Now playing'), children: [
        _row(t('Source'), _source, key: const ValueKey('quality-source')),
        if (Platform.isAndroid) ...[
          _row(t('Handed to Android'), player.item == null ? '' : formatText(a?['out'] as Map?), key: const ValueKey('quality-handed')),
          _row(t('Output'), player.item == null ? '' : _routed(a?['routed'] as Map?), key: const ValueKey('quality-output')),
          _row(t('Path'), player.item == null ? '' : a?['bitPerfect'] == true ? t('Bit-perfect') : t('Android mixer'),
              key: const ValueKey('quality-path')),
        ] else ...[
          _row(t('Output'), player.item == null ? '' : _mpvOut, key: const ValueKey('quality-output')),
          if (Platform.isLinux || Platform.isWindows)
            _row(t('Path'), player.item == null ? '' : _desktopBitPerfect ? t('Bit-perfect') : t('System mixer'),
                key: const ValueKey('quality-path')),
        ],
      ]),
      if (Platform.isAndroid) ...[
        SettingsGroup(title: t('This device'), children: [
          _row('Android', a == null ? '' : '${a['android']} · ${a['model']}'),
          _row(t('USB audio'), a == null ? '' : a['usb'] == null ? t('None connected') : '${a['usb']}', key: const ValueKey('quality-usb')),
          if (a?['usb'] != null) ...[
            _row(t('Offered over USB'), offeredText(a!['offered'] as List)),
            _row(t('Bit-perfect'), offersBitPerfect(a['offered'] as List) ? t('Offered') : t('Not offered by this device'),
                key: const ValueKey('quality-offered')),
          ],
        ]),
        SettingsGroup(children: [_bitPerfect(a), _lower()]),
      ],
      if (Platform.isLinux || Platform.isWindows) ...[
        SettingsGroup(title: t('This device'), children: [
          _row(Platform.isLinux ? 'Linux' : 'Windows', _os),
          _row(t('USB audio'), _dacs.isEmpty ? t('None connected') : _dacs.first.name, key: const ValueKey('quality-usb')),
          // Linux knows the formats of the DAC (/proc/asound); Windows decides them in WASAPI.
          if (_dacs.isNotEmpty && _dacs.first.rates.isNotEmpty) ...[
            _row(t('Offered over USB'),
                offeredText([for (final r in _dacs.first.rates) {'encoding': '${_dacs.first.bits}', 'rate': r}])),
            _row(t('Bit-perfect'), t('Offered'), key: const ValueKey('quality-offered')),
          ],
        ]),
        SettingsGroup(children: [
          _bitPerfectTile(
            ok: _dacs.isNotEmpty || qualityPrefs.bitPerfect,
            hint: t('Needs a USB DAC.'),
            confirm: _confirmOnDesktop,
          ),
        ]),
      ],
    ]);
  }

  /// libmpv plays on the DAC itself and hands it data at the title's rate (Linux: ALSA hw, Windows: WASAPI
  /// exclusive).
  bool get _desktopBitPerfect {
    final dac = qualityPrefs.desktopDac;
    if (dac == null || _desktop['audio-device'] != dac.device) return false;
    final out = _desktop['audio-out-params/samplerate'] ?? '';
    final rate = player.item?.quality?.sampleRate;
    return out.isNotEmpty && (rate == null || out == '$rate');
  }

  /// Usable with Android 14 and a USB DAC offered bit-perfect; while on it stays usable to turn it off.
  bool _available(Map? a) {
    if (a != null && (a['test'] as int? ?? 0) != 0) return true; // debug.audiojoe.int_output (BitPerfect.java)
    if (a == null || (a['sdk'] as int? ?? 0) < 34) return false;
    if (qualityPrefs.bitPerfect) return true;
    return a['usb'] != null && offersBitPerfect(a['offered'] as List);
  }

  Widget _bitPerfect(Map? a) => _bitPerfectTile(
        ok: _available(a),
        hint: t('Needs Android 14 and a USB DAC for which the device offers bit-perfect.'),
        confirm: _confirmOn,
      );

  Widget _bitPerfectTile({required bool ok, required String hint, required Future<bool> Function() confirm}) {
    return SwitchListTile(
      key: const ValueKey('bit-perfect'),
      contentPadding: EdgeInsets.zero,
      title: Text(t('Bit-perfect over USB')),
      subtitle: Text(ok ? t('Music goes unchanged to the USB DAC. Podcasts and audiobooks keep the normal path.') : hint),
      value: qualityPrefs.bitPerfect,
      onChanged: !ok
          ? null
          : (v) async {
              try {
                if (v && !await confirm()) return;
                await qualityPrefs.set(bitPerfect: v);
              } catch (e, s) {
                bitPerfectLog('switch failed: $e', s);
              }
            },
    );
  }

  Widget _lower() => SwitchListTile(
        key: const ValueKey('bit-perfect-lower'),
        contentPadding: EdgeInsets.zero,
        title: Text(t('Lower volume before bit-perfect playback')),
        subtitle: Text(t('Sets the media volume to 20 % before the first title after connecting.')),
        value: qualityPrefs.lower,
        onChanged: (v) async {
          if (!v && !await _confirmOff()) return;
          await qualityPrefs.set(lower: v);
        },
      );

  /// Android: the full-screen red warning (0.3.2, user „246 ja“).
  Future<bool> _confirmOn() => confirmBitPerfect(context, desktop: false);

  /// Linux/Windows: the full-screen red warning (0.3.2, user „251 ja“).
  Future<bool> _confirmOnDesktop() => confirmBitPerfect(context, desktop: true);

  Future<bool> _confirmOff() async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          key: const ValueKey('bit-perfect-risk'),
          icon: const Icon(Icons.hearing_disabled),
          title: Text(t('Risk of hearing damage')),
          content: Text(t('Without lowering, bit-perfect playback can start at full level. With sensitive in-ear headphones this can damage your hearing.')),
          actions: [
            TextButton(key: const ValueKey('lower-off'), onPressed: () => Navigator.pop(c, true), child: Text(t('Turn off anyway'))),
            FilledButton(onPressed: () => Navigator.pop(c, false), child: Text(t('Keep lowering'))),
          ],
        ),
      ) ==
      true;
}
