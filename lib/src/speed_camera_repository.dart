import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'speed_camera_data.dart';

/// Stores the latest validated dataset for offline use; no location history.
/// A SQLite spatial index is planned once road-matching is implemented.
class SpeedCameraRepository {
  SpeedCameraRepository({required this.baseUrl, http.Client? client})
    : _client = client ?? http.Client();

  static const String _cacheKey = 'speed_camera_npa7320_snapshot_v1';
  final String baseUrl;
  final http.Client _client;
  Future<SpeedCameraCatalog>? _refreshInFlight;

  static const _maxSnapshotBytes = 15 * 1024 * 1024;

  Uri _uri(String path) =>
      Uri.parse('${baseUrl.replaceFirst(RegExp(r"/+$"), "")}$path');

  Future<SpeedCameraCatalog?> readCached() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_cacheKey);
    if (raw == null || raw.length > _maxSnapshotBytes) return null;
    try {
      final data = jsonDecode(raw);
      if (data is! Map<String, dynamic>) return null;
      return SpeedCameraCatalog.fromJson(data);
    } on FormatException {
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<SpeedCameraCatalog> refresh() {
    return _refreshInFlight ??= _refresh().whenComplete(() {
      _refreshInFlight = null;
    });
  }

  Future<SpeedCameraCatalog> _refresh() async {
    final manifest = await _client
        .get(_uri('/api/speed-cameras/manifest'))
        .timeout(const Duration(seconds: 15));
    if (manifest.statusCode != 200) {
      throw StateError('測速資料服務暫時無法取得（HTTP ${manifest.statusCode}）');
    }
    if (manifest.bodyBytes.length > 4096) {
      throw const FormatException('測速資料版本資訊過大');
    }
    final metadata = jsonDecode(utf8.decode(manifest.bodyBytes));
    if (metadata is! Map<String, dynamic> ||
        metadata['version'] is! String ||
        (metadata['version'] as String).isEmpty ||
        (metadata['version'] as String).length > 64 ||
        metadata['recordCount'] is! int) {
      throw const FormatException('測速資料版本資訊錯誤');
    }
    final expectedVersion = metadata['version'] as String;
    final cached = await readCached();
    if (cached != null && cached.version == expectedVersion) {
      return cached;
    }

    final uri = _uri(
      '/api/speed-cameras/snapshot',
    ).replace(queryParameters: {'version': expectedVersion});
    final request = http.Request('GET', uri)..followRedirects = false;
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200 ||
        (response.contentLength ?? 0) > _maxSnapshotBytes) {
      await response.stream.listen(null).cancel();
      throw StateError('測速資料下載失敗（HTTP ${response.statusCode}）');
    }
    var total = 0;
    final raw = await response.stream
        .timeout(const Duration(seconds: 15))
        .map((chunk) {
          total += chunk.length;
          if (total > _maxSnapshotBytes) {
            throw const FormatException('測速資料超過大小限制');
          }
          return chunk;
        })
        .transform(utf8.decoder)
        .join();
    final data = jsonDecode(raw);
    if (data is! Map<String, dynamic>) {
      throw const FormatException('測速資料回應格式錯誤');
    }
    final catalog = SpeedCameraCatalog.fromJson(data);
    if (catalog.version != expectedVersion ||
        catalog.points.length != metadata['recordCount']) {
      throw const FormatException('測速資料版本或筆數不一致');
    }
    // Save only after the full snapshot validates, retaining the previous version.
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setString(_cacheKey, raw)) {
      throw StateError('無法儲存離線測速資料');
    }
    return catalog;
  }

  Future<SpeedCameraCatalog> load() async {
    try {
      return await refresh();
    } catch (_) {
      final cached = await readCached();
      if (cached != null) return cached;
      rethrow;
    }
  }

  void dispose() => _client.close();
}
