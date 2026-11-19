import 'package:flutter_test/flutter_test.dart';
import 'package:taiwan_speed_camera/taiwan_speed_camera.dart';

SpeedCameraRoadSegment eastbound(String id, double latitude) =>
    SpeedCameraRoadSegment(
      id: id,
      geometry: [
        RoadCoordinate(latitude, 121.50),
        RoadCoordinate(latitude, 121.51),
      ],
    );

void main() {
  test('distinguishes separated parallel roads and opposing headings', () {
    final matcher = SpeedCameraRoadMatcher(
      segments: [eastbound('main', 25), eastbound('service', 25.00035)],
      cameraRoadIds: {'camera': 'main'},
    );
    String? match(double latitude, double heading) => matcher.match(
      latitude: latitude,
      longitude: 121.505,
      accuracyMeters: 8,
      headingDegrees: heading,
    );
    expect(match(25, 90), 'main');
    expect(match(25.00035, 90), 'service');
    expect(match(25, 270), isNull);
    expect(matcher.cameraRoadId('camera'), 'main');
  });

  test('abstains on overlapping or ambiguous graded roads', () {
    final matcher = SpeedCameraRoadMatcher(
      segments: [eastbound('ground', 25), eastbound('overpass', 25.00002)],
      cameraRoadIds: {'camera': 'overpass'},
    );
    expect(
      matcher.match(
        latitude: 25,
        longitude: 121.505,
        accuracyMeters: 8,
        headingDegrees: 90,
      ),
      isNull,
    );
  });
}
