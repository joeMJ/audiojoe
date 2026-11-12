// Full-screen red warning before "Bit-perfect over USB" is switched on (0.3.2). User 2026-11-12: „Das DAC
// Lautstärkeproblem MUSS jetzt sofort gelöst werden. Und zwar vorab durch eine Knallrote Warnmeldung über das
// gesamte Display beim Aktivieren des Schalters und einer genauen Erklärung des zu erwartenden Verhaltens.“
// Look and texts: „246 ja“ (Android), „251 ja“ (Ubuntu, Windows): whole red page, white text, warning sign;
// "Switch on" only after the tick "I have read the warning"; "Cancel" highlighted.
// Background (0.3.1): with bit-perfect Android and the desktop compute no volume; a DAC without a volume
// control that the phone or system can operate plays at its full level, and the lowering to 20 % on Android
// then has no effect.

import 'package:flutter/material.dart';

import '../l10n.dart';

/// The red of the page; white text on it has a contrast of about 5.5 : 1.
const warningRed = Color(0xFFD50000);

/// Shows the warning over the whole display; true only after the tick and "Switch on". Back, Escape and
/// "Cancel" give false.
Future<bool> confirmBitPerfect(BuildContext context, {required bool desktop}) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      useSafeArea: false,
      builder: (_) => BitPerfectWarning(desktop: desktop),
    ) ==
    true;

class BitPerfectWarning extends StatefulWidget {
  const BitPerfectWarning({super.key, required this.desktop});

  /// Ubuntu and Windows (libmpv on the DAC itself); otherwise Android.
  final bool desktop;

  @override
  State<BitPerfectWarning> createState() => _BitPerfectWarningState();
}

class _BitPerfectWarningState extends State<BitPerfectWarning> {
  bool _read = false;

  String get _intro => widget.desktop
      ? t('With bit-perfect, music bypasses the volume control of the system and goes directly to the USB DAC.')
      : t('With bit-perfect, music goes to the USB DAC without the volume control of the phone.');

  List<String> get _points => widget.desktop
      ? [
          t('If the DAC has no volume control that the system can operate, music always plays at the full volume of the DAC. The volume control of the system then has no effect.'),
          t('Full volume can start immediately or with the next music title.'),
          t('Full volume can destroy in-ear headphones and permanently damage hearing.'),
          t('While audiojoe plays this way, other programs cannot use the DAC.'),
        ]
      : [
          t('If the DAC has no volume control that the phone can operate, music always plays at the full volume of the DAC. The volume buttons of the phone and the lowering to 20 % then have no effect.'),
          t('The change takes effect from the next music title. The current title can be quiet, and the next one starts at full volume.'),
          t('Full volume can destroy in-ear headphones and permanently damage hearing.'),
        ];

  String get _closing => widget.desktop
      ? t('Take the headphones out of your ears before switching on. Check the volume with the headphones in your hand.')
      : t('Take the headphones out of your ears before switching on. Check the volume at the next title with the headphones in your hand.');

  @override
  Widget build(BuildContext context) {
    const white = Colors.white;
    const text = TextStyle(color: white, fontSize: 17, height: 1.4);
    return Dialog.fullscreen(
      key: const ValueKey('bit-perfect-confirm'),
      backgroundColor: warningRed,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: DefaultTextStyle.merge(
                style: text,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.warning_amber_rounded, color: white, size: 72),
                  const SizedBox(height: 12),
                  Text(t('Danger to hearing and headphones'),
                      style: const TextStyle(color: white, fontSize: 28, fontWeight: FontWeight.w800, height: 1.2)),
                  const SizedBox(height: 20),
                  Text(_intro),
                  const SizedBox(height: 12),
                  for (final p in _points)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('•  ', style: TextStyle(fontWeight: FontWeight.w800)),
                        Expanded(child: Text(p)),
                      ]),
                    ),
                  const SizedBox(height: 20),
                  Text(_closing, style: const TextStyle(fontWeight: FontWeight.w800)),
                  // Android: the note on system sounds from the former question (AOSP AudioPolicyManager,
                  // user 2026-11-10 „172 ja“), at the bottom of the page (user 2026-11-12 „256 ja“).
                  if (!widget.desktop) ...[
                    const SizedBox(height: 16),
                    Text(t('While music plays bit-perfect, system sounds such as touch tones are muted, and a notification sound mutes the music while it plays. Ringtone and alarm still sound.')),
                  ],
                  const SizedBox(height: 24),
                  InkWell(
                    key: const ValueKey('bit-perfect-read'),
                    onTap: () => setState(() => _read = !_read),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(children: [
                        Checkbox(
                          value: _read,
                          onChanged: (v) => setState(() => _read = v ?? false),
                          activeColor: white,
                          checkColor: warningRed,
                          side: const BorderSide(color: white, width: 2),
                        ),
                        const SizedBox(width: 4),
                        Expanded(child: Text(t('I have read the warning'), style: const TextStyle(fontWeight: FontWeight.w700))),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Wrap(alignment: WrapAlignment.end, spacing: 12, runSpacing: 12, children: [
                    OutlinedButton(
                      key: const ValueKey('bit-perfect-on'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: white,
                        disabledForegroundColor: white.withValues(alpha: 0.55),
                        side: BorderSide(color: _read ? white : white.withValues(alpha: 0.55), width: 1.5),
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                      ),
                      onPressed: _read ? () => Navigator.pop(context, true) : null,
                      child: Text(t('Switch on')),
                    ),
                    FilledButton(
                      key: const ValueKey('bit-perfect-cancel'),
                      style: FilledButton.styleFrom(
                        backgroundColor: white,
                        foregroundColor: warningRed,
                        textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                      ),
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(t('Cancel')),
                    ),
                  ]),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
