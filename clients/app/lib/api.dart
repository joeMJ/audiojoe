// Server API with bearer token; tracks whether the server is reachable.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class ApiError implements Exception {
  final int status;
  final String message;
  ApiError(this.status, this.message);
  @override
  String toString() => message;
}

class Api {
  Api._();
  static final instance = Api._();

  final client = http.Client();
  String base = '';
  String? token;
  String device = '';
  final online = ValueNotifier<bool>(true);

  Map<String, String> get authHeaders => token == null ? {} : {'authorization': 'Bearer $token'};

  Uri uri(String path, [Map<String, String>? query]) => Uri.parse('$base/api/v1$path').replace(queryParameters: query);

  /// JSON request; `text` sends a plain body instead (e.g. an OPML file). Non-JSON answers
  /// come back as text.
  Future<dynamic> call(String method, String path,
      {Object? body, String? text, Map<String, String>? query, Duration timeout = const Duration(seconds: 30)}) async {
    final req = http.Request(method, uri(path, query))..headers.addAll(authHeaders);
    if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.body = jsonEncode(body);
    } else if (text != null) {
      req.headers['content-type'] = 'text/plain; charset=utf-8';
      req.body = text;
    }
    http.Response res;
    try {
      res = await http.Response.fromStream(await client.send(req).timeout(timeout));
    } catch (e) {
      online.value = false;
      throw ApiError(0, '$e');
    }
    // Behind the reverse proxy a stopped server shows up as 502/503/504: that is "offline".
    if (res.statusCode >= 502 && res.statusCode <= 504) {
      online.value = false;
      throw ApiError(0, 'server unavailable (${res.statusCode})');
    }
    online.value = true;
    final json = (res.headers['content-type'] ?? '').contains('json');
    final data = res.body.isEmpty ? null : json ? jsonDecode(res.body) : res.body;
    if (res.statusCode >= 400) {
      throw ApiError(res.statusCode, data is Map ? '${data['error']}' : res.reasonPhrase ?? '${res.statusCode}');
    }
    return data;
  }

  /// Stream URL of an item (part: file index of multi-file books).
  Uri streamUri(String key, {int? part}) =>
      uri('/stream/${Uri.encodeComponent(key)}', part == null ? null : {'part': '$part'});

  Uri imageUri(String path) => Uri.parse('$base$path');

  // ---------------------------------------------------------------- credentials

  static const _secure = FlutterSecureStorage();

  /// Token storage: the platform's secret store; without one (e.g. a Linux session without
  /// keyring) a file readable only by the user.
  Future<File> _fallback() async => File('${(await getApplicationSupportDirectory()).path}/session.json');

  Future<void> saveSession() async {
    final data = jsonEncode({'base': base, 'token': token, 'device': device});
    try {
      await _secure.write(key: 'session', value: data);
    } catch (_) {
      final f = await _fallback();
      await f.writeAsString(data);
      if (!Platform.isWindows) await Process.run('chmod', ['600', f.path]);
    }
  }

  Future<bool> loadSession() async {
    String? data;
    try {
      data = await _secure.read(key: 'session');
    } catch (_) {}
    if (data == null) {
      final f = await _fallback();
      if (await f.exists()) data = await f.readAsString();
    }
    if (data == null) return false;
    final j = jsonDecode(data) as Map<String, dynamic>;
    base = j['base'] as String;
    token = j['token'] as String?;
    device = (j['device'] ?? '') as String;
    return token != null;
  }

  Future<void> clearSession() async {
    token = null;
    try {
      await _secure.delete(key: 'session');
    } catch (_) {}
    final f = await _fallback();
    if (await f.exists()) await f.delete();
  }

  Future<void> login(String server, String user, String password, String code, String deviceName) async {
    var b = server.trim().replaceAll(RegExp(r'/+$'), '');
    if (!b.contains('://')) b = 'https://$b';
    base = b;
    final r = await call('POST', '/auth/login',
        body: {'username': user.trim(), 'password': password, 'totp': code.trim(), 'device': deviceName.trim()});
    token = r['token'] as String;
    device = r['device'] as String;
    await saveSession();
  }
}

final api = Api.instance;
