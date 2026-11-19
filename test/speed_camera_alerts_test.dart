import 'package:flutter_test/flutter_test.dart';
import 'package:taiwan_speed_camera/src/speed_camera_alerts.dart';
import 'package:taiwan_speed_camera/taiwan_speed_camera.dart';

SpeedCameraPoint point(String id, double longitude, String direction) =>
    SpeedCameraPoint(
      id: id,
      latitude: 25.025,
      longitude: longitude,
      address: '測試路',
      directionRaw: direction,
      speedLimitKmh: 60,
    );

void main() {
  test('filters opposing compass labels, preserves unknown candidates', () {
    final result = SpeedCameraDetector.findAhead(
      [
        point('opposing', 121.535, '東向西'),
        point('matching', 121.536, '東西雙向（區間測速）'),
        point('unknown', 121.537, '往大溪方向'),
      ],
      latitude: 25.025,
      longitude: 121.532,
      accuracyMeters: 8,
      headingDegrees: 90,
    );
    expect(result.map((candidate) => candidate.point.id), [
      'matching',
      'unknown',
    ]);
    expect(result.map((candidate) => candidate.directionSupported), [
      true,
      false,
    ]);
  });

  test('requires consecutive approach and suppresses a nearby duplicate', () {
    final alerts = SpeedCameraAlerts();
    final time = DateTime.utc(2026, 11, 19);
    final original = point('first', 121.535, '往東');
    final duplicate = point('duplicate', 121.5352, '往東');
    bool sample(SpeedCameraPoint point, double meters, int seconds) =>
        alerts.shouldSpeak(
          SpeedCameraCandidate(point, meters, directionSupported: true),
          time.add(Duration(seconds: seconds)),
        );

    expect(sample(original, 380, 0), false);
    expect(sample(original, 379, 3), false);
    expect(sample(original, 340, 6), true);
    expect(sample(original, 300, 9), false);
    expect(sample(duplicate, 310, 56), false);
    expect(sample(duplicate, 290, 59), false);
    expect(sample(original, 380, 300), false);
    expect(sample(original, 360, 303), true);
  });
}
