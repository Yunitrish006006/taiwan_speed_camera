import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';

import 'speed_camera_data.dart';

/// Confirms reported speed with displacement rather than summing GPS jitter.
class SpeedCameraMotion {
  Position? _anchor;
  bool _moving = false;

  double? measure(Position position) {
    final speed = position.speed;
    if (!position.accuracy.isFinite ||
        position.accuracy < 0 ||
        position.accuracy > 50 ||
        !position.latitude.isFinite ||
        !position.longitude.isFinite ||
        !speed.isFinite ||
        speed < 0) {
      reset();
      return null;
    }

    final anchor = _anchor;
    if (anchor == null ||
        position.timestamp.difference(anchor.timestamp) >
            const Duration(seconds: 12)) {
      _anchor = position;
      _moving = false;
      return speed <= 1 ? 0 : null;
    }

    if (speed <= 1 ||
        (position.speedAccuracy.isFinite && speed <= position.speedAccuracy)) {
      _anchor = position;
      _moving = false;
      return 0;
    }

    final distance = SpeedCameraDetector.distanceMeters(
      anchor.latitude,
      anchor.longitude,
      position.latitude,
      position.longitude,
    );
    final accuracy = math.max(anchor.accuracy, position.accuracy);
    if (distance > math.max(4.0, accuracy)) _moving = true;
    if (position.timestamp.difference(anchor.timestamp) >=
        const Duration(seconds: 5)) {
      _moving = distance > math.max(4.0, accuracy);
      _anchor = position;
    }
    return _moving ? speed : 0;
  }

  void reset() {
    _anchor = null;
    _moving = false;
  }
}
