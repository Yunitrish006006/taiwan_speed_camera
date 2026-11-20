import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:taiwan_speed_camera/taiwan_speed_camera.dart';

class _Location extends GeolocatorPlatform {
  _Location() {
    positions = StreamController(onCancel: () => cancellations++);
  }

  late final StreamController<Position> positions;
  final services = StreamController<ServiceStatus>();
  LocationSettings? settings;
  int cancellations = 0;

  @override
  Future<bool> isLocationServiceEnabled() async => true;

  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.whileInUse;

  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) {
    settings = locationSettings;
    return positions.stream;
  }

  @override
  Stream<ServiceStatus> getServiceStatusStream() => services.stream;
}

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final background in [false, true]) {
      testWidgets(
        '${platform.name} location lifecycle with background=$background',
        (tester) async {
          final ttsCalls = <MethodCall>[];
          final exerciseFallback =
              platform == TargetPlatform.android && !background;
          var engineSelected = false;
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            const MethodChannel('flutter_tts'),
            (call) async {
              ttsCalls.add(call);
              if (exerciseFallback) {
                if (call.method == 'getEngines') return ['test.android.tts'];
                if (call.method == 'setEngine') engineSelected = true;
                if (call.method == 'setLanguage' && !engineSelected) return 0;
              }
              return 1;
            },
          );
          final original = GeolocatorPlatform.instance;
          final location = _Location();
          GeolocatorPlatform.instance = location;
          addTearDown(() {
            GeolocatorPlatform.instance = original;
            unawaited(location.positions.close());
            unawaited(location.services.close());
          });

          SharedPreferences.setMockInitialValues({
            'speed_camera_npa7320_snapshot_v1': jsonEncode({
              'schemaVersion': 1,
              'source': 'NPA-7320',
              'generatedAt': '2026-11-19T00:00:00Z',
              'recordCount': 1,
              'points': [
                {
                  'id': 'npa7320:test',
                  'address': '測試路',
                  'latitude': 25,
                  'longitude': 121,
                  'directionRaw': '往東',
                },
              ],
            }),
          });
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await tester.pumpWidget(
            const MaterialApp(
              home: SpeedCameraPage(
                apiBaseUrl: 'https://example.test',
                backgroundLocationAvailable: true,
              ),
            ),
          );
          await tester.pumpAndSettle();
          if (background) {
            final toggle = find.text('鎖定螢幕後繼續本次行程');
            await tester.ensureVisible(toggle);
            await tester.tap(toggle);
            await tester.pumpAndSettle();
          }
          if (exerciseFallback) {
            final preview = find.text('試播語音提醒');
            await tester.ensureVisible(preview);
            await tester.tap(preview);
            await tester.pumpAndSettle();
            expect(engineSelected, isTrue);
            expect(
              ttsCalls.where((call) => call.method == 'speak'),
              hasLength(1),
            );
            ttsCalls.clear();
          }
          final start = find.text('開始行車模式');
          await tester.scrollUntilVisible(start, 120);
          await tester.pumpAndSettle();
          await tester.tap(start);
          await tester.pumpAndSettle();
          final settings = location.settings!;
          switch (settings) {
            case AndroidSettings():
              expect(platform, TargetPlatform.android);
              expect(settings.foregroundNotificationConfig != null, background);
            case AppleSettings():
              expect(platform, TargetPlatform.iOS);
              expect(settings.allowBackgroundLocationUpdates, background);
              expect(settings.showBackgroundLocationIndicator, background);
            default:
              fail('Expected native location settings');
          }
          final now = DateTime.now();
          Position sample(double longitude, int secondsAgo) => Position(
            longitude: longitude,
            latitude: 25,
            timestamp: now.subtract(Duration(seconds: secondsAgo)),
            accuracy: 8,
            altitude: 0,
            altitudeAccuracy: 0,
            heading: 90,
            headingAccuracy: 7,
            speed: 12,
            speedAccuracy: 1,
          );
          location.positions.add(sample(120.997, 3));
          await tester.pump();
          expect(ttsCalls.where((call) => call.method == 'speak'), isEmpty);
          location.positions.add(sample(120.9974, 2));
          await tester.pumpAndSettle();
          expect(ttsCalls.where((call) => call.method == 'speak'), isEmpty);
          location.positions.add(sample(120.9978, 1));
          await tester.pumpAndSettle();
          expect(
            ttsCalls.where((call) => call.method == 'speak'),
            hasLength(1),
          );
          location.positions.add(sample(120.9982, 0));
          await tester.pumpAndSettle();
          expect(
            ttsCalls.where((call) => call.method == 'speak'),
            hasLength(1),
          );

          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
          await tester.pumpAndSettle();
          expect(location.cancellations, background ? 0 : 1);
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await tester.pumpAndSettle();

          if (background) {
            location.services.add(ServiceStatus.disabled);
            await tester.pumpAndSettle();
            expect(location.cancellations, 1);
            expect(find.textContaining('定位已中斷'), findsOneWidget);
          }
          await tester.pumpWidget(const SizedBox());
          expect(location.cancellations, 1);
          expect(ttsCalls.any((call) => call.method == 'stop'), isTrue);
        },
        variant: TargetPlatformVariant({platform}),
      );
    }
  }
}
