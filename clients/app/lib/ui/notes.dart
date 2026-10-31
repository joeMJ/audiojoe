// Shownotes: the server's filtered HTML (paragraphs, lists, headings, emphasis, links) as
// selectable text with tappable links.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:url_launcher/url_launcher.dart';

class NotesView extends StatefulWidget {
  final String html;
  const NotesView(this.html, {super.key});

  @override
  State<NotesView> createState() => _NotesViewState();
}

class _NotesViewState extends State<NotesView> {
  final _taps = <TapGestureRecognizer>[];

  @override
  void dispose() {
    for (final r in _taps) {
      r.dispose();
    }
    super.dispose();
  }

  static const _blocks = {'p', 'li', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'blockquote'};

  @override
  Widget build(BuildContext context) {
    for (final r in _taps) {
      r.dispose();
    }
    _taps.clear();
    final base = const TextStyle(fontSize: 15, height: 1.45);
    final link = TextStyle(color: Theme.of(context).colorScheme.primary, decoration: TextDecoration.underline, fontWeight: FontWeight.w600);
    final out = <Widget>[];

    List<InlineSpan> inline(dom.Node n, TextStyle s) {
      if (n is dom.Text) return [TextSpan(text: n.text.replaceAll(RegExp(r'\s+'), ' '), style: s)];
      if (n is! dom.Element) return [];
      switch (n.localName) {
        case 'br':
          return [const TextSpan(text: '\n')];
        case 'b' || 'strong':
          s = s.merge(const TextStyle(fontWeight: FontWeight.w800));
        case 'i' || 'em':
          s = s.merge(const TextStyle(fontStyle: FontStyle.italic));
        case 'a':
          final uri = Uri.tryParse(n.attributes['href'] ?? '');
          if (uri != null && const {'http', 'https', 'mailto'}.contains(uri.scheme)) {
            final r = TapGestureRecognizer()..onTap = () => launchUrl(uri, mode: LaunchMode.externalApplication);
            _taps.add(r);
            return [TextSpan(text: n.text, style: s.merge(link), recognizer: r)];
          }
      }
      return [for (final c in n.nodes) ...inline(c, s)];
    }

    void block(List<InlineSpan> spans, {String prefix = '', TextStyle? style, double indent = 0}) {
      if (spans.every((s) => s is TextSpan && (s.text ?? '').trim().isEmpty)) return;
      out.add(Padding(
        padding: EdgeInsets.only(left: indent, bottom: 10),
        child: Text.rich(TextSpan(children: [if (prefix.isNotEmpty) TextSpan(text: prefix), ...spans]), style: style ?? base),
      ));
    }

    void walk(dom.Node n, double indent) {
      if (n is! dom.Element) {
        block(inline(n, base), indent: indent);
        return;
      }
      final tag = n.localName ?? '';
      if (tag == 'ul' || tag == 'ol') {
        var i = 0;
        for (final li in n.children.where((c) => c.localName == 'li')) {
          i++;
          block([for (final c in li.nodes.where((c) => !(c is dom.Element && (c.localName == 'ul' || c.localName == 'ol')))) ...inline(c, base)],
              prefix: tag == 'ol' ? '$i. ' : '•  ', indent: indent + 8);
          for (final sub in li.children.where((c) => c.localName == 'ul' || c.localName == 'ol')) {
            walk(sub, indent + 20);
          }
        }
      } else if (tag.startsWith('h') && _blocks.contains(tag)) {
        block(inline(n, base), style: base.merge(const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)), indent: indent);
      } else if (_blocks.contains(tag)) {
        block([for (final c in n.nodes) ...inline(c, base)], indent: indent + (tag == 'blockquote' ? 14 : 0));
      } else {
        // Inline elements at the top level form their own paragraph.
        block(inline(n, base), indent: indent);
      }
    }

    final body = html.parse(widget.html).body;
    for (final n in body?.nodes ?? <dom.Node>[]) {
      walk(n, 0);
    }
    return SelectionArea(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: out));
  }
}
