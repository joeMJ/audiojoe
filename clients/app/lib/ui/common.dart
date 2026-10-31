// Theme from the shared design tokens and small shared widgets.

import 'package:flutter/material.dart';

import '../api.dart';
import '../downloads.dart';
import '../l10n.dart';
import '../models.dart';
import '../sync.dart';
import '../tokens.g.dart';

/// Colours beyond the Material scheme (status colours, secondary surfaces).
class Tok extends ThemeExtension<Tok> {
  final Color panel2, muted, line, ok, okBg, warn, warnBg, bad, badBg;
  const Tok(this.panel2, this.muted, this.line, this.ok, this.okBg, this.warn, this.warnBg, this.bad, this.badBg);

  static const light = Tok(LightTokens.panel2, LightTokens.muted, LightTokens.line, LightTokens.ok, LightTokens.okBg,
      LightTokens.warn, LightTokens.warnBg, LightTokens.bad, LightTokens.badBg);
  static const dark = Tok(DarkTokens.panel2, DarkTokens.muted, DarkTokens.line, DarkTokens.ok, DarkTokens.okBg,
      DarkTokens.warn, DarkTokens.warnBg, DarkTokens.bad, DarkTokens.badBg);

  @override
  Tok copyWith() => this;
  @override
  Tok lerp(Tok? other, double t) => t < .5 ? this : (other ?? this);
}

extension TokOf on BuildContext {
  Tok get tok => Theme.of(this).extension<Tok>()!;
}

ThemeData buildTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final scheme = ColorScheme(
    brightness: b,
    primary: dark ? DarkTokens.accent : LightTokens.accent,
    onPrimary: dark ? DarkTokens.accentText : LightTokens.accentText,
    secondary: dark ? DarkTokens.accent : LightTokens.accent,
    onSecondary: dark ? DarkTokens.accentText : LightTokens.accentText,
    error: dark ? DarkTokens.bad : LightTokens.bad,
    onError: dark ? DarkTokens.bg : LightTokens.panel,
    surface: dark ? DarkTokens.panel : LightTokens.panel,
    onSurface: dark ? DarkTokens.text : LightTokens.text,
    surfaceContainerHighest: dark ? DarkTokens.panel2 : LightTokens.panel2,
    outline: dark ? DarkTokens.line : LightTokens.line,
  );
  final r = BorderRadius.circular(SizeTokens.radius);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark ? DarkTokens.bg : LightTokens.bg,
    extensions: [dark ? Tok.dark : Tok.light],
    cardTheme: CardThemeData(
      color: scheme.surface,
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: r, side: BorderSide(color: scheme.outline, width: 2)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: const Size(88, SizeTokens.touchPhone), shape: RoundedRectangleBorder(borderRadius: r)),
    ),
    inputDecorationTheme: InputDecorationTheme(border: OutlineInputBorder(borderRadius: r)),
  );
}

/// Server reachable / offline, and positions waiting for sync.
class StatusPills extends StatelessWidget {
  const StatusPills({super.key});

  @override
  Widget build(BuildContext context) {
    final k = context.tok;
    Widget pill(String text, Color fg, Color bg, {bool dot = false}) => Container(
          margin: const EdgeInsets.only(left: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(99)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (dot) ...[Container(width: 9, height: 9, decoration: BoxDecoration(color: fg, shape: BoxShape.circle)), const SizedBox(width: 6)],
            Text(text, style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 13)),
          ]),
        );
    return ListenableBuilder(
      listenable: Listenable.merge([api.online, sync.pendingCount]),
      builder: (context, _) => Row(mainAxisSize: MainAxisSize.min, children: [
        api.online.value
            ? pill(t('Server reachable'), k.ok, k.okBg, dot: true)
            : pill(t('Offline · cache'), k.warn, k.warnBg, dot: true),
        if (sync.pendingCount.value > 0)
          pill(t('{n} waiting to sync', {'n': sync.pendingCount.value}), k.warn, k.warnBg)
        else
          pill(t('Positions synced'), k.muted, k.panel2),
      ]),
    );
  }
}

class CoverThumb extends StatelessWidget {
  final String? image;
  final String label;
  final double size;
  const CoverThumb({super.key, this.image, required this.label, this.size = 44});

  @override
  Widget build(BuildContext context) {
    final k = context.tok;
    final initials = label.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).take(3).map((w) => w[0]).join().toUpperCase();
    final fallback = Center(child: Text(initials.isEmpty ? '♫' : initials, style: TextStyle(color: k.muted, fontWeight: FontWeight.w800)));
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: size,
        height: size,
        color: k.panel2,
        child: image == null || !api.online.value
            ? fallback
            : Image.network(api.imageUri(image!).toString(), headers: api.authHeaders, fit: BoxFit.cover,
                errorBuilder: (_, _, _) => fallback),
      ),
    );
  }
}

class Badge2 extends StatelessWidget {
  final String text;
  final String kind; // ok | warn | bad | plain
  const Badge2(this.text, {super.key, this.kind = 'plain'});

  @override
  Widget build(BuildContext context) {
    final k = context.tok;
    final (fg, bg) = switch (kind) { 'ok' => (k.ok, k.okBg), 'warn' => (k.warn, k.warnBg), 'bad' => (k.bad, k.badBg), _ => (k.muted, k.panel2) };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text(text, style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 12)),
    );
  }
}

/// Status of an item's offline copy, or null when there is none.
Widget? offlineBadge(String key) {
  final e = downloads.entry(key);
  if (e == null) return null;
  return switch (e.status) {
    'done' => Badge2(t('in cache'), kind: 'ok'),
    'error' => Badge2(t('failed'), kind: 'bad'),
    'loading' => Badge2(t('loading {p}', {'p': '${(e.progress * 100).round()} %'}), kind: 'warn'),
    _ => Badge2(t('waiting'), kind: 'warn'),
  };
}

class ItemRow extends StatelessWidget {
  final Widget leading;
  final String title, subtitle;
  final double? progress;
  final List<Widget> trailing;
  final VoidCallback? onTap;
  const ItemRow({super.key, required this.leading, required this.title, this.subtitle = '', this.progress,
      this.trailing = const [], this.onTap});

  @override
  Widget build(BuildContext context) {
    final k = context.tok;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(SizeTokens.radius),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: SizeTokens.touchPhone + 8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(children: [
              leading,
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  if (subtitle.isNotEmpty)
                    Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: k.muted)),
                  if (progress != null && progress! > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: LinearProgressIndicator(value: progress, minHeight: 5, borderRadius: BorderRadius.circular(3), backgroundColor: k.panel2),
                    ),
                ]),
              ),
              for (final w in trailing) Padding(padding: const EdgeInsets.only(left: 8), child: w),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Loads data and shows it; errors and offline state as text.
class Loader<T> extends StatefulWidget {
  final Future<T> Function() load;
  final Widget Function(BuildContext, T, VoidCallback reload) builder;
  const Loader({super.key, required this.load, required this.builder});

  @override
  State<Loader<T>> createState() => _LoaderState<T>();
}

class _LoaderState<T> extends State<Loader<T>> {
  late Future<T> _f = widget.load();

  @override
  Widget build(BuildContext context) => FutureBuilder<T>(
        future: _f,
        builder: (context, s) {
          if (s.hasError) {
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Text(api.online.value ? '${t('Error')}: ${s.error}' : t('Server not reachable.'),
                  style: TextStyle(color: context.tok.muted, fontSize: 16)),
            );
          }
          if (!s.hasData) return const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()));
          return widget.builder(context, s.data as T, () => setState(() => _f = widget.load()));
        },
      );
}

Widget emptyText(BuildContext context, String s) =>
    Padding(padding: const EdgeInsets.all(20), child: Text(s, style: TextStyle(color: context.tok.muted, fontSize: 16)));

List<Item> itemsOf(dynamic list) => (list as List).map((e) => Item.fromJson((e as Map).cast<String, dynamic>())).toList();
