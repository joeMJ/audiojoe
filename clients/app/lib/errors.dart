// Errors of the app on this device (user 2026-11-07, way C): a release build shows a box with the
// message instead of the grey ErrorWidget, and keeps the last 50 errors in a file on the device
// (Settings → Maintenance → "Error log"). Nothing leaves the device unless the user shares it.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'l10n.dart';

class ErrorEntry {
  final String at, message, stack;
  final int count;
  const ErrorEntry({required this.at, required this.message, required this.stack, this.count = 1});

  static ErrorEntry fromJson(Map j) => ErrorEntry(
      at: '${j['at']}', message: '${j['message']}', stack: '${j['stack'] ?? ''}', count: (j['count'] ?? 1) as int);
  Map<String, dynamic> toJson() => {'at': at, 'message': message, 'stack': stack, 'count': count};
}

class ErrorLog extends ChangeNotifier {
  ErrorLog._();
  static final instance = ErrorLog._();

  static const max = 50;
  /// Lines of the stack trace kept per entry.
  static const stackLines = 20;

  File? _file;
  List<ErrorEntry> entries = [];
  bool _writing = false, _again = false;

  /// Reads the log and catches the app's errors from here on.
  Future<void> open(Directory dir) async {
    _file = File('${dir.path}/errors.json');
    try {
      entries = ((jsonDecode(await _file!.readAsString()) as List).cast<Map>()).map(ErrorEntry.fromJson).toList();
    } catch (_) {
      entries = [];
    }
    final flutter = FlutterError.onError;
    FlutterError.onError = (d) {
      record(d.exceptionAsString(), d.stack);
      (flutter ?? FlutterError.presentError)(d);
    };
    final platform = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (e, s) {
      record('$e', s);
      return platform?.call(e, s) ?? false;
    };
    if (kReleaseMode) ErrorWidget.builder = (d) => ErrorBox(d.exceptionAsString());
  }

  /// One error; the same message again (an error in every frame) counts up the newest entry.
  void record(String message, StackTrace? stack) {
    final now = DateTime.now().toUtc().toIso8601String();
    final trace = (stack?.toString() ?? '').split('\n').where((l) => l.trim().isNotEmpty).take(stackLines).join('\n');
    if (entries.isNotEmpty && entries.first.message == message) {
      entries.first = ErrorEntry(at: now, message: message, stack: trace, count: entries.first.count + 1);
    } else {
      entries.insert(0, ErrorEntry(at: now, message: message, stack: trace));
      if (entries.length > max) entries.removeRange(max, entries.length);
    }
    unawaited(_save());
    // Not during a build (the error may come from one): listeners rebuild after this frame.
    scheduleMicrotask(notifyListeners);
  }

  Future<void> _save() async {
    if (_file == null) return;
    if (_writing) {
      _again = true;
      return;
    }
    _writing = true;
    try {
      do {
        _again = false;
        await _file!.writeAsString(jsonEncode(entries.map((e) => e.toJson()).toList()));
      } while (_again);
    } catch (_) {
    } finally {
      _writing = false;
    }
  }

  /// The log as text to read or pass on.
  String text(String version) {
    final b = StringBuffer('audiojoe $version · ${Platform.operatingSystem} ${Platform.operatingSystemVersion}\n');
    for (final e in entries) {
      b.write('\n${e.at}${e.count > 1 ? ' (${e.count}×)' : ''}\n${e.message}\n');
      if (e.stack.isNotEmpty) b.write('${e.stack}\n');
    }
    return b.toString();
  }
}

final errorLog = ErrorLog.instance;

/// In place of a part that failed to build (release builds; the debug builds keep Flutter's red box).
class ErrorBox extends StatelessWidget {
  final String message;
  const ErrorBox(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Container(
        margin: const EdgeInsets.all(8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: c.errorContainer, borderRadius: BorderRadius.circular(8)),
        child: DefaultTextStyle(
          style: TextStyle(color: c.onErrorContainer, fontSize: 14),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t('Error showing this page:'), style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(message, maxLines: 12, overflow: TextOverflow.ellipsis),
          ]),
        ),
      ),
    );
  }
}
