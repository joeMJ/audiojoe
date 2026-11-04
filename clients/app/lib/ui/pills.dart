// The pills at the top (user 2026-11-04, order as in the car): Cache, Server, Position, and on
// Linux and Windows "Storage" and the round moon. Same shape as before.

import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../appearance.dart';
import '../cache.dart';
import '../downloads.dart';
import '../l10n.dart';
import '../models.dart';
import '../player.dart';
import '../remote.dart';
import '../sonos.dart';
import '../storage.dart';
import '../sync.dart';
import 'common.dart';

/// One pill. `outline`: no colour, only a frame in the text colour (white dark, black light).
Widget pill(BuildContext context, String text,
    {Color? fg, Color? bg, bool dot = false, IconData? icon, String? tip, bool outline = false, VoidCallback? onTap, double? minWidth, Key? key}) {
  final scheme = Theme.of(context).colorScheme;
  final color = fg ?? scheme.onSurface;
  Widget p = Container(
    key: key,
    constraints: BoxConstraints(minWidth: minWidth ?? 0),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: outline ? Colors.transparent : bg,
      borderRadius: BorderRadius.circular(99),
      border: outline ? Border.all(color: scheme.onSurface, width: 1.5) : null,
    ),
    child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
      if (dot) ...[Container(width: 9, height: 9, decoration: BoxDecoration(color: color, shape: BoxShape.circle)), const SizedBox(width: 6)],
      if (icon != null) ...[Icon(icon, size: 15, color: color), const SizedBox(width: 4)],
      Text(text,
          style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 13, height: outline ? 1.0 : null,
              fontFeatures: const [FontFeature.tabularFigures()])),
    ]),
  );
  if (onTap != null) {
    p = Material(
      color: Colors.transparent,
      child: InkWell(borderRadius: BorderRadius.circular(99), onTap: onTap, child: p),
    );
  }
  p = Padding(padding: const EdgeInsets.only(left: 6), child: p);
  return tip == null ? p : Tooltip(message: tip, child: p);
}

/// Server reachable / offline, and positions synced / waiting for sync.
class StatusPills extends StatelessWidget {
  const StatusPills({super.key});

  @override
  Widget build(BuildContext context) {
    final k = context.tok;
    return ListenableBuilder(
      listenable: Listenable.merge([api.online, sync.stale, sync.pendingCount]),
      builder: (context, _) => Row(mainAxisSize: MainAxisSize.min, children: [
        api.online.value
            ? pill(context, t('Server'), fg: k.ok, bg: k.okBg, dot: true, tip: t('Server reachable'))
            : pill(context, t('Offline · cache'), fg: k.warn, bg: k.warnBg, dot: true),
        sync.stale.value
            ? pill(context, t('Position'), fg: k.bad, bg: k.badBg, icon: Icons.close,
                tip: sync.pendingCount.value == 1
                    ? t('1 position waiting for the server')
                    : t('{n} positions waiting for the server', {'n': sync.pendingCount.value}))
            : pill(context, t('Position'), fg: k.ok, bg: k.okBg, icon: Icons.check, tip: t('Positions synced')),
      ]),
    );
  }
}

/// How much of what plays now is saved here; a tap saves the rest. Radio and playback on another
/// device or a Sonos speaker: only "Cache" in a frame.
class CachePill extends StatefulWidget {
  const CachePill({super.key});
  @override
  State<CachePill> createState() => _CachePillState();
}

class _CachePillState extends State<CachePill> {
  final scope = CacheScope();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([player, downloads, remote, sonos, storage]),
        builder: (context, _) {
          final k = context.tok;
          final it = player.item;
          final elsewhere = remote.active || sonos.output != null;
          final neutral = pill(context, t('Cache'), outline: true, minWidth: 104, key: const ValueKey('cache-pill'));
          if (it == null || elsewhere || player.live) return neutral;
          return FutureBuilder<List<Item>>(
            future: scope.of(it, player.queue),
            initialData: scope.last,
            builder: (context, snap) {
              final items = snap.data ?? const [];
              if (items.isEmpty) return neutral;
              final p = savedPercent(items, downloads.entry);
              final full = p == 100;
              return pill(context, t('Cache {p}', {'p': '$p %'}),
                  key: const ValueKey('cache-pill'),
                  fg: full ? k.ok : k.warn,
                  bg: full ? k.okBg : k.warnBg,
                  minWidth: 104,
                  tip: full ? null : t('Save offline'),
                  onTap: full ? null : () => unawaited(downloads.add(items)));
            },
          );
        },
      );
}

/// Linux and Windows: opens the saved titles; red when nothing more can be saved (below "Keep at
/// least … free"). No size: it moved while titles were saved.
class StoragePill extends StatelessWidget {
  final bool open;
  final VoidCallback onTap;
  const StoragePill({super.key, required this.open, required this.onTap});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: storage,
        builder: (context, _) {
          final k = context.tok, scheme = Theme.of(context).colorScheme;
          final low = storage.low;
          return pill(context, t('Storage'),
              key: const ValueKey('storage-pill'),
              fg: low ? k.bad : open ? scheme.onPrimary : scheme.onSurface,
              bg: low ? k.badBg : open ? scheme.primary : k.panel2,
              tip: low ? t('Waiting for space') : null,
              onTap: onTap);
        },
      );
}

/// Round moon as big as the pills: dark mode on (filled, accent) or off (outline).
class MoonButton extends StatelessWidget {
  const MoonButton({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: appearance,
        builder: (context, mode, _) {
          final on = isDark(context), scheme = Theme.of(context).colorScheme;
          return Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Tooltip(
              message: on ? t('Dark mode: on') : t('Dark mode: off'),
              child: Material(
                key: const ValueKey('moon'),
                color: on ? scheme.primary : Colors.transparent,
                shape: CircleBorder(side: on ? BorderSide.none : BorderSide(color: scheme.onSurface, width: 1.5)),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => toggleDark(context),
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: Icon(on ? Icons.dark_mode : Icons.dark_mode_outlined, size: 17, color: on ? scheme.onPrimary : scheme.onSurface),
                  ),
                ),
              ),
            ),
          );
        },
      );
}
