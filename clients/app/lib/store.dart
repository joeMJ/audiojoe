// Small persistent key-value stores as JSON files in the app's data directory:
//   pending   – playback updates not yet sent to the server
//   positions – last known position per item (works offline)
//   offline   – metadata and status of offline titles
//   items     – item metadata for offline use

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class Store {
  final String name;
  final Map<String, Map<String, dynamic>> data = {};
  late final File _file;
  Timer? _timer;

  Store(this.name);

  Future<void> open(Directory dir) async {
    _file = File('${dir.path}/$name.json');
    if (await _file.exists()) {
      try {
        final j = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
        j.forEach((k, v) => data[k] = (v as Map).cast<String, dynamic>());
      } catch (_) {
        // A damaged file must not block the app; it is rebuilt from the server.
      }
    }
  }

  Map<String, dynamic>? get(String key) => data[key];

  void put(String key, Map<String, dynamic> value) {
    data[key] = value;
    _save();
  }

  void remove(String key) {
    data.remove(key);
    _save();
  }

  void _save() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 300), flush);
  }

  Future<void> flush() async {
    _timer?.cancel();
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode(data));
    await tmp.rename(_file.path);
  }
}

class Stores {
  static final pending = Store('pending');
  static final positions = Store('positions');
  static final offline = Store('offline');
  static final items = Store('items');
  static late Directory dir;

  static Future<void> open() async {
    dir = Directory('${(await getApplicationSupportDirectory()).path}/audiojoe');
    await dir.create(recursive: true);
    for (final s in [pending, positions, offline, items]) {
      await s.open(dir);
    }
  }

  static Future<void> clear() async {
    for (final s in [pending, positions, offline, items]) {
      s.data.clear();
      await s.flush();
    }
  }
}
