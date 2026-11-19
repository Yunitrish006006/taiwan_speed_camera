import 'dart:math' as math;

import 'speed_camera_data.dart';

class RoadCoordinate {
  const RoadCoordinate(this.latitude, this.longitude);

  final double latitude;
  final double longitude;
}

/// A directed carriageway polyline. Model opposite carriageways, ramps and
/// vertically overlapping roads as distinct IDs. Each ID must be stable
/// within one road dataset version.
class SpeedCameraRoadSegment {
  SpeedCameraRoadSegment({
    required this.id,
    required Iterable<RoadCoordinate> geometry,
    this.bidirectional = false,
  }) : geometry = List.unmodifiable(geometry) {
    if (id.isEmpty || this.geometry.length < 2) {
      throw ArgumentError(
        'Road segment requires an ID and at least two vertices',
      );
    }
    if (this.geometry.any(
      (point) =>
          !point.latitude.isFinite ||
          point.latitude.abs() > 90 ||
          !point.longitude.isFinite ||
          point.longitude.abs() > 180,
    )) {
      throw ArgumentError('Invalid road geometry coordinates');
    }
  }

  final String id;
  final List<RoadCoordinate> geometry;
  final bool bidirectional;
}

/// Selects a plausible carriageway using offline, versioned geometry. Close
/// rivals are treated as ambiguous. The caller supplies nearby road segments
/// and verified camera-to-segment bindings for the same region and version.
class SpeedCameraRoadMatcher {
  SpeedCameraRoadMatcher({
    required Iterable<SpeedCameraRoadSegment> segments,
    required Map<String, String> cameraRoadIds,
  }) : _segments = List.unmodifiable(segments),
       _cameraRoadIds = Map.unmodifiable(cameraRoadIds) {
    final ids = _segments.map((segment) => segment.id).toSet();
    if (ids.length != _segments.length ||
        _cameraRoadIds.values.any((id) => !ids.contains(id))) {
      throw ArgumentError('Camera bindings must reference unique road IDs');
    }
  }

  final List<SpeedCameraRoadSegment> _segments;
  final Map<String, String> _cameraRoadIds;

  String? cameraRoadId(String pointId) => _cameraRoadIds[pointId];

  String? match({
    required double latitude,
    required double longitude,
    required double accuracyMeters,
    required double headingDegrees,
  }) {
    if (!latitude.isFinite ||
        latitude.abs() > 90 ||
        !longitude.isFinite ||
        longitude.abs() > 180 ||
        !headingDegrees.isFinite ||
        headingDegrees < 0 ||
        headingDegrees > 360 ||
        !accuracyMeters.isFinite ||
        accuracyMeters < 0 ||
        accuracyMeters > 25) {
      return null;
    }
    final maxCrossTrack = math.max(12.0, accuracyMeters);
    final ambiguousWithin = math.max(6.0, accuracyMeters);
    const metersPerDegree =
        SpeedCameraDetector.earthRadiusMeters * math.pi / 180;
    final longitudeScale = metersPerDegree * math.cos(latitude * math.pi / 180);
    String? bestId;
    var bestScore = double.infinity;
    var runnerUpScore = double.infinity;
    for (final road in _segments) {
      var roadScore = double.infinity;
      for (var i = 1; i < road.geometry.length; i++) {
        final start = road.geometry[i - 1];
        final end = road.geometry[i];
        final ax = (start.longitude - longitude) * longitudeScale;
        final ay = (start.latitude - latitude) * metersPerDegree;
        final dx = (end.longitude - start.longitude) * longitudeScale;
        final dy = (end.latitude - start.latitude) * metersPerDegree;
        final squareLength = dx * dx + dy * dy;
        if (squareLength == 0) continue;
        final projection = (-(ax * dx + ay * dy) / squareLength).clamp(
          0.0,
          1.0,
        );
        final x = ax + dx * projection;
        final y = ay + dy * projection;
        final distance = math.sqrt(x * x + y * y);
        if (distance > maxCrossTrack) continue;
        final bearing = (math.atan2(dx, dy) * 180 / math.pi + 360) % 360;
        var delta = ((headingDegrees - bearing + 540) % 360 - 180).abs();
        if (road.bidirectional) delta = math.min(delta, 180 - delta);
        if (delta > 35) continue;
        roadScore = math.min(roadScore, distance + delta * 0.2);
      }
      if (roadScore < bestScore) {
        runnerUpScore = bestScore;
        bestScore = roadScore;
        bestId = road.id;
      } else if (roadScore < runnerUpScore) {
        runnerUpScore = roadScore;
      }
    }
    return runnerUpScore - bestScore >= ambiguousWithin ? bestId : null;
  }
}
