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
    for (final mode in [
      'foreground',
      'background',
      if (platform == TargetPlatform.android) 'overlay',
    ]) {
      final background = mode != 'foreground';
      final overlay = mode == 'overlay';
      testWidgets('${platform.name} location lifecycle with $mode', (
        tester,
      ) async {
        final overlayCalls = <MethodCall>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('taiwan_brawl/speed_overlay'),
          (call) async {
            overlayCalls.add(call);
            return call.method == 'allowed' ? true : null;
          },
        );
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
          if (overlay) 'speed_camera_overlay_speed_sp': 80,
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
          MaterialApp(
            home: SpeedCameraPage(
              apiBaseUrl: 'https://example.test',
              backgroundLocationAvailable: true,
              androidOverlayAvailable: overlay,
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (overlay) {
          await tester.tap(find.byTooltip('測速設定'));
          await tester.pumpAndSettle();
          expect(find.text('浮窗車速數字大小：80 sp'), findsOneWidget);
          await tester.tapAt(
            tester.getRect(find.byType(Slider).first).centerRight -
                const Offset(2, 0),
          );
          await tester.pumpAndSettle();
          expect(find.text('浮窗車速數字大小：352 sp'), findsOneWidget);
          expect(
            (await SharedPreferences.getInstance()).getInt(
              'speed_camera_overlay_speed_sp',
            ),
            352,
          );
          await tester.tap(find.byKey(const ValueKey('overlayTransparency')));
          await tester.pumpAndSettle();
          expect(find.text('背景透明度：50%'), findsOneWidget);
          for (final choice in [('overlayInk', '黃色'), ('overlayFill', '黑色')]) {
            await tester.tap(find.byKey(ValueKey(choice.$1)));
            await tester.pumpAndSettle();
            await tester.tap(find.text(choice.$2).last);
            await tester.pumpAndSettle();
          }
          final appearance = await SharedPreferences.getInstance();
          expect(appearance.getInt('speed_camera_overlay_transparency'), 50);
          expect(appearance.getInt('speed_camera_overlay_ink'), 0xffffd54f);
          expect(appearance.getInt('speed_camera_overlay_fill'), 0xff000000);
          await tester.pageBack();
          await tester.pumpAndSettle();
        }
        if (background) {
          final toggle = find.text(overlay ? '桌面測速浮窗' : '鎖定螢幕後繼續本次行程');
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
        expect(ttsCalls.where((call) => call.method == 'speak'), hasLength(1));
        location.positions.add(sample(120.9982, 0));
        await tester.pumpAndSettle();
        expect(ttsCalls.where((call) => call.method == 'speak'), hasLength(1));

        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
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
        if (overlay) {
          expect(
            overlayCalls.any(
              (call) =>
                  call.method == 'update' &&
                  call.arguments['speed'] != null &&
                  call.arguments['sizeSp'] == 352 &&
                  call.arguments['transparency'] == 50 &&
                  call.arguments['ink'] == 0xffffd54f &&
                  call.arguments['fill'] == 0xff000000,
            ),
            isTrue,
          );
          expect(overlayCalls.last.method, 'clear');
        }
        await tester.pumpWidget(const SizedBox());
        expect(location.cancellations, 1);
        expect(ttsCalls.any((call) => call.method == 'stop'), isTrue);
      }, variant: TargetPlatformVariant({platform}));
    }
  }
}
