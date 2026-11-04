// Storage of this device: free space and "Keep at least … free". Below the limit no download
// starts and none is queued (user 2026-11-04, moved forward from 0.2.0); the storage pill turns
// red. Decimal GB (10^9 bytes), as shown ("GB ist ein Zeichen weniger").
//
// The free space comes from the platform through a method channel: statvfs (Linux),
// GetDiskFreeSpaceExW (Windows), StatFs (Android).

import 'dart:async';

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

  /// Free bytes where the downloads are; null while unknown (then nothing is blocked).
  int? free;

  int get keepFreeGb => ((Stores.device.get('storage')?['keep_free_gb'] as num?)?.toInt() ?? minKeepFreeGb).clamp(minKeepFreeGb, 100000);

  set keepFreeGb(int v) {
    Stores.device.put('storage', {'keep_free_gb': v < minKeepFreeGb ? minKeepFreeGb : v});
    notifyListeners();
  }

  /// Below the limit: no download starts.
  bool get low => free != null && free! < keepFreeGb * gb;

  Timer? _timer;

  Future<void> refresh() async {
    String path;
    try {
      path = Stores.dir.path;
    } catch (_) {
      path = '.'; // stores not opened (tests)
    }
    final f = await probe(path);
    if (f == free) return;
    free = f;
    notifyListeners();
  }

  /// Checked once a minute as well: other programs fill the disk too.
  void start() {
    unawaited(refresh());
    _timer ??= Timer.periodic(const Duration(minutes: 1), (_) => unawaited(refresh()));
  }
}

final storage = Storage.instance;
