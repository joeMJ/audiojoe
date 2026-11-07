// Storage of this device: where downloads go, free space and "Keep at least … free". Below the
// limit no download starts and none is queued (user 2026-11-04, moved forward from 0.2.0); the
// storage pill turns red. Decimal GB (10^9 bytes), as shown ("GB ist ein Zeichen weniger").
//
// 0.2.0 (user 2026-11-07): downloads go into sub-folders podcasts, audiobooks and music of the
// storage folder. Linux and Windows: "audiojoe" in the home folder unless the user picked another
// ("7 im persönlichen Benutzerordner"); Android: the app's own storage, no choice of folder.
//
// The free space comes from the platform through a method channel: statvfs (Linux),
// GetDiskFreeSpaceExW (Windows), StatFs (Android).

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'store.dart';

const gb = 1000 * 1000 * 1000;

class Storage extends ChangeNotifier {
  Storage._();
  static final instance = Storage._();

  /// Default and smallest value (user: "Minimum 5GiB", 5 GB, steps of 1 GB).
  static const minKeepFreeGb = 5;

  static const _channel = MethodChannel('io.github.joemj.audiojoe/storage');

  /// Free bytes of the volume of `path`; tests replace it.
  @visibleForTesting
  static Future<int?> Function(String path) probe = (path) async {
    try {
      return await _channel.invokeMethod<int>('free', path);
    } catch (_) {
      return null;
    }
  };

  /// Free bytes of the volume of `path` (null when unknown).
  static Future<int?> freeAt(String path) => probe(existing(path));

  /// Free bytes where the downloads are; null while unknown (then nothing is blocked).
  int? free;

  Map<String, dynamic> get _settings => Stores.device.get('storage') ?? const {};

  void _put(String key, Object? value) {
    Stores.device.put('storage', {..._settings, key: value});
    notifyListeners();
  }

  int get keepFreeGb => ((_settings['keep_free_gb'] as num?)?.toInt() ?? minKeepFreeGb).clamp(minKeepFreeGb, 100000);

  set keepFreeGb(int v) => _put('keep_free_gb', v < minKeepFreeGb ? minKeepFreeGb : v);

  /// "Delete after listening" for podcasts (default on) and audiobooks (default off), as in the
  /// mockup ("15ja"). Music stays until it is deleted.
  bool deleteAfter(String kind) => switch (kind) {
        'episode' => _settings['delete_podcasts'] as bool? ?? true,
        'book' => _settings['delete_books'] as bool? ?? false,
        _ => false,
      };

  void setDeleteAfter(String kind, bool on) => _put(kind == 'book' ? 'delete_books' : 'delete_podcasts', on);

  /// Whether the user can choose the storage folder (Linux, Windows).
  static bool get desktop => Platform.isLinux || Platform.isWindows;

  /// Default storage folder of the desktop: "audiojoe" in the home folder.
  static String defaultDir() {
    final home = Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'] ?? '.';
    return '$home${Platform.pathSeparator}audiojoe';
  }

  /// The storage folder: where new downloads go (each entry keeps its own path).
  Directory get dir {
    if (!desktop) return Directory('${_storesDir()}/offline');
    final d = _settings['dir'] as String?;
    return Directory(d == null || d.isEmpty ? defaultDir() : d);
  }

  /// "Change …": new downloads go to `path`; what is saved stays where it is ("12 ja").
  set dir(Directory d) => _put('dir', d.path);

  static String _storesDir() {
    try {
      return Stores.dir.path;
    } catch (_) {
      return '.'; // stores not opened (tests)
    }
  }

  /// Below the limit: no download starts.
  bool get low => free != null && free! < keepFreeGb * gb;

  Timer? _timer;

  Future<void> refresh() async {
    final f = await probe(existing(dir.path));
    if (f == free) return;
    free = f;
    notifyListeners();
  }

  /// The folder itself or its nearest existing parent (the storage folder is made on first use).
  static String existing(String path) {
    var d = Directory(path).absolute;
    while (!d.existsSync() && d.parent.path != d.path) {
      d = d.parent;
    }
    return d.path;
  }

  /// Checked once a minute as well: other programs fill the disk too.
  void start() {
    unawaited(refresh());
    _timer ??= Timer.periodic(const Duration(minutes: 1), (_) => unawaited(refresh()));
  }
}

final storage = Storage.instance;
