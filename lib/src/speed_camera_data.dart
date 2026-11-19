import 'dart:math' as math;

class SpeedCameraPoint {
  const SpeedCameraPoint({
    required this.id,
    required this.latitude,
    required this.longitude,
    required this.address,
    required this.directionRaw,
    required this.speedLimitKmh,
  });

  final String id;
  final double latitude;
  final double longitude;
  final String address;
  final String directionRaw;
  final int? speedLimitKmh;

  static SpeedCameraPoint fromJson(Map<String, dynamic> map) {
    final lat = map['latitude'];
    final lng = map['longitude'];
    final id = map['id'];
    final address = map['address'];
    if (id is! String ||
        !id.startsWith('npa7320:') ||
        address is! String ||
        address.trim().isEmpty ||
        lat is! num ||
        lng is! num ||
        !lat.isFinite ||
        !lng.isFinite ||
        lat < 18 ||
        lat > 27 ||
        lng < 115 ||
        lng > 124) {
      throw const FormatException('測速點資料有誤');
    }
    final rawLimit = map['speedLimitKmh'];
    if (rawLimit != null &&
        (rawLimit is! int || rawLimit < 10 || rawLimit > 130)) {
      throw const FormatException('測速點速限格式錯誤');
    }
    return SpeedCameraPoint(
      id: id,
      latitude: lat.toDouble(),
      longitude: lng.toDouble(),
      address: address,
      directionRaw: map['directionRaw'] is String
          ? map['directionRaw'] as String
          : '',
      speedLimitKmh: rawLimit as int?,
    );
  }
}

class SpeedCameraCatalog {
  const SpeedCameraCatalog({
    required this.version,
    required this.generatedAt,
    required this.points,
  });

  final String version;
  final String generatedAt;
  final List<SpeedCameraPoint> points;

  factory SpeedCameraCatalog.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1 ||
        json['source'] != 'NPA-7320' ||
        json['points'] is! List ||
        json['recordCount'] != (json['points'] as List).length) {
      throw const FormatException('測速資料版本或內容格式錯誤');
    }
    final entries = json['points'] as List;
    if (entries.isEmpty || entries.length > 30000) {
      throw const FormatException('測速資料筆數不合理');
    }
    final ids = <String>{};
    final points = entries
        .map((entry) {
          if (entry is! Map) throw const FormatException('測速點格式錯誤');
          final point = SpeedCameraPoint.fromJson(
            Map<String, dynamic>.from(entry),
          );
          if (!ids.add(point.id)) throw const FormatException('測速點識別碼重複');
          return point;
        })
        .toList(growable: false);
    final generatedAt = json['generatedAt'];
    final version = json['contentSha256'] ?? generatedAt;
    if (version is! String ||
        version.isEmpty ||
        generatedAt is! String ||
        DateTime.tryParse(generatedAt) == null) {
      throw const FormatException('缺少測速資料版本');
    }
    return SpeedCameraCatalog(
      version: version,
      generatedAt: generatedAt,
      points: List.unmodifiable(points),
    );
  }
}

class SpeedCameraCandidate {
  const SpeedCameraCandidate(
    this.point,
    this.distanceMeters, {
    this.directionSupported = false,
  });
  final SpeedCameraPoint point;
  final double distanceMeters;
  final bool directionSupported;
}

/// Spatial/heading candidate search only. Never claim road-level accuracy:
/// nearby parallel roads, elevated roads and source directions need map matching.
class SpeedCameraDetector {
  static const double earthRadiusMeters = 6371008.8;

  static const _compass = {
    '北': 0.0,
    '東北': 45.0,
    '東': 90.0,
    '東南': 135.0,
    '南': 180.0,
    '西南': 225.0,
    '西': 270.0,
    '西北': 315.0,
  };
  static const _cardinal = '東北|東南|西北|西南|東|西|南|北';
  static final _between = RegExp('^($_cardinal)[向往]($_cardinal)(?:方向|車道)?\$');
  static final _towards = RegExp('^往?($_cardinal)(?:向|方向|車道)?\$');
  static final _annotation = RegExp(r'[(（](?:區間測速|超速闖紅燈)[)）]$');

  // Only explicit compass labels are interpreted. Destinations and ambiguous
  // annotations remain unknown, and the road itself is still unverified.
  static List<double>? _travelBearings(String raw) {
    final value = raw
        .replaceAll(RegExp(r'\s+'), '')
        .replaceFirst(_annotation, '');
    switch (value) {
      case '雙向':
      case '雙向區間測速':
        return const [];
      case '南北雙向':
      case '南北向':
      case '北南雙向':
        return const [0, 180];
      case '東西雙向':
      case '東西向':
      case '西東雙向':
        return const [90, 270];
      case '北上':
      case '北上方向':
      case '北上車道':
        return const [0];
      case '南下':
      case '南下方向':
      case '南下車道':
        return const [180];
    }
    final pair = _between.firstMatch(value);
    if (pair != null) {
      final from = _compass[pair.group(1)]!;
      final to = _compass[pair.group(2)]!;
      return _angularDistance(from, to) == 180 ? [to] : null;
    }
    final direction = _towards.firstMatch(value);
    return direction == null ? null : [_compass[direction.group(1)]!];
  }

  static double _angularDistance(double a, double b) =>
      ((a - b + 540) % 360 - 180).abs();

  static double _rad(double degrees) => degrees * math.pi / 180;

  static double distanceMeters(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) {
    final dLat = _rad(lat2 - lat1);
    final dLng = _rad(lng2 - lng1);
    final a =
        math.pow(math.sin(dLat / 2), 2) +
        math.cos(_rad(lat1)) *
            math.cos(_rad(lat2)) *
            math.pow(math.sin(dLng / 2), 2);
    final h = a.toDouble().clamp(0.0, 1.0);
    return 2 * earthRadiusMeters * math.atan2(math.sqrt(h), math.sqrt(1 - h));
  }

  static double bearingDegrees(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) {
    final y = math.sin(_rad(lng2 - lng1)) * math.cos(_rad(lat2));
    final x =
        math.cos(_rad(lat1)) * math.sin(_rad(lat2)) -
        math.sin(_rad(lat1)) *
            math.cos(_rad(lat2)) *
            math.cos(_rad(lng2 - lng1));
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  static List<SpeedCameraCandidate> findAhead(
    List<SpeedCameraPoint> points, {
    required double latitude,
    required double longitude,
    required double accuracyMeters,
    required double headingDegrees,
    double radiusMeters = 600,
    double maxHeadingDeviation = 60,
  }) {
    if (!latitude.isFinite ||
        !longitude.isFinite ||
        !accuracyMeters.isFinite ||
        accuracyMeters < 0 ||
        accuracyMeters > 50 ||
        !headingDegrees.isFinite ||
        headingDegrees < 0 ||
        headingDegrees > 360) {
      return const [];
    }
    final heading = (headingDegrees % 360 + 360) % 360;
    final found = <SpeedCameraCandidate>[];
    for (final point in points) {
      final distance = distanceMeters(
        latitude,
        longitude,
        point.latitude,
        point.longitude,
      );
      if (distance < 5 || distance > radiusMeters) continue;
      final bearing = bearingDegrees(
        latitude,
        longitude,
        point.latitude,
        point.longitude,
      );
      if (_angularDistance(bearing, heading) > maxHeadingDeviation) continue;
      final travelBearings = _travelBearings(point.directionRaw);
      if (travelBearings != null &&
          travelBearings.isNotEmpty &&
          !travelBearings.any(
            (direction) => _angularDistance(direction, heading) <= 45,
          )) {
        continue;
      }
      found.add(
        SpeedCameraCandidate(
          point,
          distance,
          directionSupported: travelBearings != null,
        ),
      );
    }
    found.sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));
    return found;
  }
}
