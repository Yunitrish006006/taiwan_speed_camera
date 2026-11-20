import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:taiwan_speed_camera/src/speed_camera_motion.dart';

Position sample(int seconds, double longitude, {double speed = 11 / 3.6}) =>
    Position(
      latitude: 25,
      longitude: longitude,
      timestamp: DateTime.utc(2026, 11, 20).add(Duration(seconds: seconds)),
      accuracy: 8,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 90,
      headingAccuracy: 7,
      speed: speed,
      speedAccuracy: 0.5,
    );

void main() {
  test('stationary jitter does not display a reported 11 km/h', () {
    final motion = SpeedCameraMotion();
    expect(motion.measure(sample(0, 121)), isNull);
    expect(motion.measure(sample(2, 121.00003)), 0);
    expect(motion.measure(sample(4, 120.99996)), 0);
    expect(motion.measure(sample(6, 121.00002)), 0);
  });

  test('confirms slow travel, then clears on a stationary sample', () {
    final motion = SpeedCameraMotion();
    expect(motion.measure(sample(0, 121)), isNull);
    expect(motion.measure(sample(2, 121.00003)), 0);
    expect(motion.measure(sample(4, 121.0001)), closeTo(11 / 3.6, 0.001));
    expect(motion.measure(sample(6, 121.00011, speed: 0.2)), 0);
  });
}
