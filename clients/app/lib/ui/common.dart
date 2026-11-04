// Theme from the shared design tokens and small shared widgets.

import 'dart:io';

import 'package:flutter/material.dart';

import '../api.dart';
import '../downloads.dart';
import '../l10n.dart';
import '../models.dart';
import '../tokens.g.dart';

/// Linux and Windows: player buttons at the bottom right next to the cover, no volume of this
/// device, settings on pages. Tests set it.
bool desktop = Platform.isLinux || Platform.isWindows;

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

/// Server path of an item's cover (404 when it has none: the thumb then shows initials).
String coverOf(String key) => '/api/v1/image/${Uri.encodeComponent(key)}';

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

/// Primary button of a list row; fixed width so rows line up whatever the label.
/// Play button of a row: phones get a round icon button, so the title keeps its room.
Widget playButton(BuildContext context, String label, VoidCallback? onPressed) => MediaQuery.sizeOf(context).width >= 720
    ? rowButton(label, onPressed)
    : IconButton.filled(tooltip: label, onPressed: onPressed, icon: const Icon(Icons.play_arrow));

Widget rowButton(String label, VoidCallback? onPressed) =>
    SizedBox(width: 124, child: FilledButton(onPressed: onPressed, child: Text(label, maxLines: 1, overflow: TextOverflow.fade, softWrap: false)));

/// Offline state of an item as a fixed-size icon (download button when there is no copy).
Widget offlineIcon(BuildContext context, String key, {VoidCallback? onSave, bool showOnlineOnly = false}) {
  final k = context.tok;
  final e = downloads.entry(key);
  Widget icon(IconData i, Color c, String tip) => Tooltip(message: tip, child: Icon(i, color: c, size: 28));
  final Widget child = switch (e?.status) {
    'done' => icon(Icons.download_done, k.ok, t('in cache')),
    'error' => icon(Icons.error_outline, k.bad, t('failed')),
    'loading' => Tooltip(
        message: t('loading {p}', {'p': '${((e?.progress ?? 0) * 100).round()} %'}),
        child: SizedBox(width: 26, height: 26, child: CircularProgressIndicator(value: e?.progress, strokeWidth: 3))),
    String() => icon(Icons.schedule, k.warn, t('waiting')),
    null when onSave != null => IconButton.outlined(tooltip: t('Save offline'), onPressed: onSave, icon: const Icon(Icons.download)),
    null => showOnlineOnly ? icon(Icons.cloud_outlined, k.muted, t('online only')) : const SizedBox.shrink(),
  };
  return SizedBox(width: 48, height: 48, child: Center(child: child));
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
  final VoidCallback? onTap, onLongPress;
  final bool highlight; // framed in the ok colour, e.g. the next volume of a series
  const ItemRow({super.key, required this.leading, required this.title, this.subtitle = '', this.progress,
      this.trailing = const [], this.onTap, this.onLongPress, this.highlight = false});

  @override
  Widget build(BuildContext context) {
    final k = context.tok;
    return Card(
      shape: highlight
          ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(SizeTokens.radius), side: BorderSide(color: k.ok, width: 2))
          : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(SizeTokens.radius),
        onTap: onTap,
        onLongPress: onLongPress,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: SizeTokens.touchPhone + 8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(children: [
              leading,
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
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

/// One line, centred when it fits; otherwise it flows to the left again and again, with a
/// 2 s pause at the start of each round. Without animations (accessibility) it is cut off.
class Marquee extends StatefulWidget {
  final InlineSpan text;
  final TextStyle style;
  const Marquee(this.text, {super.key, required this.style});

  @override
  State<Marquee> createState() => _MarqueeState();
}

class _MarqueeState extends State<Marquee> with SingleTickerProviderStateMixin {
  static const _gap = 48.0, _speed = 35.0; // px per second
  late final AnimationController _c = AnimationController(vsync: this);
  double _width = 0; // one round (text + gap); 0 when the text fits
  int _round = 0; // a new text or size starts a new loop
  bool _running = false;

  @override
  void didUpdateWidget(Marquee old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) _restart();
  }

  // Called while building: stopping does not notify, the offset is reset after the frame.
  void _restart() {
    _round++;
    _running = false;
    _c.stop();
  }

  @override
  void dispose() {
    _round++;
    _c.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    if (_running) return;
    _running = true;
    final round = _round;
    while (mounted && round == _round && _width > 0) {
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted || round != _round || _width == 0) break;
      _c.duration = Duration(milliseconds: (_width / _speed * 1000).round());
      try {
        await _c.forward(from: 0).orCancel;
      } on TickerCanceled {
        break;
      }
      if (mounted && round == _round) _c.value = 0;
    }
    if (round == _round) _running = false;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final tp = TextPainter(
          text: TextSpan(style: DefaultTextStyle.of(context).style.merge(widget.style), children: [widget.text]),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout();
        final still = MediaQuery.of(context).disableAnimations;
        final width = tp.width <= box.maxWidth || still ? 0.0 : tp.width + _gap;
        if (width != _width) {
          _width = width;
          _restart();
        }
        if (width == 0) {
          return Text.rich(widget.text, style: widget.style, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis);
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (!_running && _c.value != 0) _c.value = 0;
          _run();
        });
        final line = Text.rich(widget.text, style: widget.style, maxLines: 1, softWrap: false);
        return SizedBox(
          width: box.maxWidth,
          height: tp.height,
          child: ClipRect(
            child: AnimatedBuilder(
              animation: _c,
              builder: (_, child) => OverflowBox(
                alignment: Alignment.centerLeft,
                maxWidth: double.infinity,
                child: Transform.translate(offset: Offset(-_c.value * _width, 0), child: child),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [line, const SizedBox(width: _gap), line]),
            ),
          ),
        );
      });
}
