import 'speed_camera_data.dart';

/// Requires repeated approach samples and suppresses nearby duplicate records.
/// GPS samples and alert history live only in memory for the current trip.
class SpeedCameraAlerts {
  SpeedCameraCandidate? _previous;
  DateTime? _previousAt;
  DateTime? _lastAlert;
  final _announced = <String, DateTime>{};
  final _nearbyAlerts = <SpeedCameraPoint, DateTime>{};

  bool shouldSpeak(SpeedCameraCandidate? candidate, DateTime sampleTime) {
    final previous = _previous;
    final previousAt = _previousAt;
    _previous = candidate;
    _previousAt = sampleTime;
    if (candidate == null ||
        !candidate.directionSupported ||
        candidate.distanceMeters > 400 ||
        previous?.point.id != candidate.point.id ||
        previousAt == null ||
        !sampleTime.isAfter(previousAt) ||
        sampleTime.difference(previousAt) > const Duration(seconds: 15) ||
        previous!.distanceMeters - candidate.distanceMeters < 3) {
      return false;
    }

    final last = _lastAlert;
    if (last != null &&
        sampleTime.difference(last) < const Duration(seconds: 20)) {
      return false;
    }
    const rearm = Duration(minutes: 4);
    _announced.removeWhere((_, time) => sampleTime.difference(time) >= rearm);
    _nearbyAlerts.removeWhere(
      (_, time) => sampleTime.difference(time) >= rearm,
    );
    final point = candidate.point;
    if (_announced.containsKey(point.id) ||
        _nearbyAlerts.keys.any(
          (other) =>
              SpeedCameraDetector.distanceMeters(
                point.latitude,
                point.longitude,
                other.latitude,
                other.longitude,
              ) <=
              90,
        )) {
      return false;
    }
    _lastAlert = sampleTime;
    _announced[point.id] = sampleTime;
    _nearbyAlerts[point] = sampleTime;
    return true;
  }
}
