import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';

import 'speed_camera_alerts.dart';
import 'speed_camera_data.dart';
import 'speed_camera_repository.dart';
import 'speed_camera_road_matcher.dart';

/// Starts a user-controlled driving session with optional native background location.
class SpeedCameraPage extends StatefulWidget {
  const SpeedCameraPage({
    super.key,
    required this.apiBaseUrl,
    this.backgroundLocationAvailable = false,
    this.roadMatcher,
  });
  final String apiBaseUrl;
  final bool backgroundLocationAvailable;
  final SpeedCameraRoadMatcher? roadMatcher;

  @override
  State<SpeedCameraPage> createState() => _SpeedCameraPageState();
}

class _SpeedCameraPageState extends State<SpeedCameraPage>
    with WidgetsBindingObserver {
  late final SpeedCameraRepository _repository;
  final FlutterTts _tts = FlutterTts();
  SpeedCameraAlerts _alerts = SpeedCameraAlerts();
  StreamSubscription<Position>? _positionSubscription;
  StreamSubscription<ServiceStatus>? _serviceSubscription;
  SpeedCameraCatalog? _catalog;
  Position? _position;
  SpeedCameraCandidate? _nearest;
  bool _loading = true;
  bool _tracking = false;
  bool _starting = false;
  bool _stopping = false;
  bool _continueInBackground = false;
  bool _voiceEnabled = true;
  bool _speaking = false;
  int _session = 0;
  String? _message;

  bool get _nativeMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  bool get _supportsBackground =>
      _nativeMobile && widget.backgroundLocationAvailable;

  bool get _isVisible =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _repository = SpeedCameraRepository(baseUrl: widget.apiBaseUrl);
    unawaited(_loadCatalog());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached ||
        (!_continueInBackground &&
            (state == AppLifecycleState.hidden ||
                state == AppLifecycleState.paused))) {
      unawaited(_stopTracking());
    }
  }

  Future<void> _loadCatalog() async {
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      final catalog = await _repository.refresh();
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        _loading = false;
      });
    } catch (_) {
      final backup = await _repository.readCached();
      if (!mounted) return;
      setState(() {
        _catalog = backup ?? _catalog;
        _loading = false;
        _message = _catalog == null
            ? '目前沒有可用的官方測速資料，請稍後再試。'
            : '連線失敗，繼續使用已下載的離線資料。';
      });
    }
  }

  LocationSettings _locationSettings() {
    const accuracy = LocationAccuracy.bestForNavigation;
    const distanceFilter = 10;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilter,
        foregroundNotificationConfig: _continueInBackground
            ? const ForegroundNotificationConfig(
                notificationTitle: '行車測速提醒',
                notificationText: '行車定位中，回到 App 可結束行車模式。',
              )
            : null,
      );
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      return AppleSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilter,
        activityType: ActivityType.automotiveNavigation,
        allowBackgroundLocationUpdates: _continueInBackground,
        showBackgroundLocationIndicator: _continueInBackground,
      );
    }
    return const LocationSettings(
      accuracy: accuracy,
      distanceFilter: distanceFilter,
    );
  }

  Future<void> _startTracking() async {
    if (_tracking ||
        _starting ||
        _stopping ||
        !_isVisible ||
        _catalog == null) {
      return;
    }
    final session = ++_session;
    setState(() {
      _starting = true;
      _message = null;
    });
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw StateError('請先開啟手機定位服務。');
      }
      if (!mounted || session != _session) return;
      var permission = LocationPermission.whileInUse;
      if (!kIsWeb) {
        permission = await Geolocator.checkPermission();
        if (!mounted || session != _session) return;
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }
      }
      if (!mounted || session != _session) return;
      if (permission != LocationPermission.whileInUse &&
          permission != LocationPermission.always) {
        throw StateError('請在系統設定允許使用 App 期間定位。');
      }
      if (!_isVisible) throw StateError('請回到行車畫面後重新開始。');

      _alerts = SpeedCameraAlerts();
      setState(() {
        _tracking = true;
        _starting = false;
      });
      _positionSubscription =
          Geolocator.getPositionStream(
            locationSettings: _locationSettings(),
          ).listen(
            (position) => _handlePosition(position, session),
            onError: (Object error) => _locationEnded(session),
            onDone: () => _locationEnded(session),
          );
      if (_nativeMobile) {
        _serviceSubscription = Geolocator.getServiceStatusStream().listen((
          status,
        ) {
          if (status == ServiceStatus.disabled) _locationEnded(session);
        }, onError: (Object error) => _locationEnded(session));
      }
    } catch (error) {
      if (!mounted || session != _session) return;
      await _stopTracking(
        message: error is StateError ? error.message : '無法啟動定位，請確認定位服務與權限。',
      );
    }
  }

  void _locationEnded(int session) {
    if (!mounted || session != _session) return;
    unawaited(_stopTracking(message: '定位已中斷，請檢查定位服務及權限後重新開始。'));
  }

  void _handlePosition(Position position, int session) {
    final catalog = _catalog;
    if (!mounted || session != _session || catalog == null || !_tracking) {
      return;
    }
    final age = DateTime.now().difference(position.timestamp);
    if (age > const Duration(seconds: 20) ||
        age < const Duration(seconds: -5) ||
        (_position != null &&
            !position.timestamp.isAfter(_position!.timestamp))) {
      return;
    }
    final candidates =
        position.speed.isFinite &&
            position.speed >= 2.5 &&
            position.headingAccuracy.isFinite &&
            position.headingAccuracy >= 0 &&
            position.headingAccuracy <= 45
        ? SpeedCameraDetector.findAhead(
            catalog.points,
            latitude: position.latitude,
            longitude: position.longitude,
            accuracyMeters: position.accuracy,
            headingDegrees: position.heading,
          )
        : const <SpeedCameraCandidate>[];
    final matcher = widget.roadMatcher;
    final roadId = candidates.isEmpty
        ? null
        : matcher?.match(
            latitude: position.latitude,
            longitude: position.longitude,
            accuracyMeters: position.accuracy,
            headingDegrees: position.heading,
          );
    final closest = candidates.where((candidate) {
      final cameraRoad = matcher?.cameraRoadId(candidate.point.id);
      return roadId == null || cameraRoad == null || roadId == cameraRoad;
    }).firstOrNull;
    final hasRoadEvidence =
        matcher == null ||
        (roadId != null &&
            closest != null &&
            matcher.cameraRoadId(closest.point.id) == roadId);
    setState(() {
      _position = position;
      _nearest = closest;
    });
    if (_nativeMobile &&
        _voiceEnabled &&
        !_speaking &&
        _alerts.shouldSpeak(
          hasRoadEvidence ? closest : null,
          position.timestamp,
        )) {
      unawaited(_speak(session));
    }
  }

  Future<void> _speak(int session) async {
    _speaking = true;
    try {
      await _tts.awaitSpeakCompletion(true);
      if (await _tts.setLanguage('zh-TW') != 1) {
        throw StateError('zh-TW voice unavailable');
      }
      await _tts.setSpeechRate(0.47);
      if (!mounted || session != _session) return;
      final result = await _tts.speak('附近有公告測速執法地點，請留意道路速限。', focus: true);
      if (result != 1) throw StateError('speech failed');
    } catch (_) {
      if (mounted && session == _session) {
        setState(() {
          _message = '語音播放失敗，請確認手機已安裝繁中語音。';
        });
      }
    } finally {
      _speaking = false;
    }
  }

  Future<void> _stopTracking({String? message}) async {
    if ((!_tracking && !_starting) || _stopping) return;
    ++_session;
    setState(() {
      _starting = false;
      _tracking = false;
      _stopping = true;
      _nearest = null;
      _position = null;
      _message = message;
    });
    try {
      await _releaseTracking();
    } finally {
      if (mounted) {
        setState(() {
          _stopping = false;
        });
      }
    }
  }

  Future<void> _releaseTracking() async {
    final position = _positionSubscription;
    final service = _serviceSubscription;
    _positionSubscription = null;
    _serviceSubscription = null;
    await Future.wait([
      if (position != null) position.cancel().catchError((Object _) {}),
      if (service != null) service.cancel().catchError((Object _) {}),
      if (_nativeMobile)
        _tts.stop().then<void>((_) {}).catchError((Object _) {}),
    ]);
  }

  @override
  void dispose() {
    ++_session;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_releaseTracking());
    _repository.dispose();
    super.dispose();
  }

  Widget _statTile(String title, String value, {Color? color}) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(color: Color(0xFF98A9C2), fontSize: 13),
          ),
          const SizedBox(height: 7),
          Text(
            value,
            style: TextStyle(
              color: color ?? Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF64E2C4);
    final measuredSpeed = _position?.speed;
    final speed =
        measuredSpeed == null || !measuredSpeed.isFinite || measuredSpeed < 0
        ? '--'
        : (measuredSpeed * 3.6).clamp(0, 250).round().toString();
    final nearest = _nearest;
    final catalog = _catalog;
    return Scaffold(
      backgroundColor: const Color(0xFF0D1422),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D1422),
        foregroundColor: Colors.white,
        title: const Text('行車測速提醒'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _loadCatalog,
            icon: const Icon(Icons.sync_rounded),
            tooltip: '檢查資料更新',
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 36),
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF1A3440), Color(0xFF142338)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: const Color(0xFF345669)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _tracking ? 'GPS 行車模式執行中' : 'GPS 行車模式已停止',
                    style: const TextStyle(color: accent, fontSize: 14),
                  ),
                  const SizedBox(height: 22),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        speed,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 80,
                          height: 1,
                          fontWeight: FontWeight.w300,
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.only(left: 10, bottom: 8),
                        child: Text(
                          'km/h',
                          style: TextStyle(
                            color: Color(0xFFB7C7D8),
                            fontSize: 19,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const Divider(color: Color(0xFF416071)),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      _statTile(
                        '附近候選測速點',
                        nearest == null
                            ? '無'
                            : '${nearest.distanceMeters.round()} m',
                        color: nearest == null ? null : accent,
                      ),
                      _statTile(
                        '公告速限',
                        nearest?.point.speedLimitKmh == null
                            ? '--'
                            : '${nearest!.point.speedLimitKmh} km/h',
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            if (nearest != null)
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: const Color(0xFF17263A),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '附近測速執法點（尚未完成道路匹配）',
                      style: TextStyle(
                        color: accent,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      nearest.point.address,
                      style: const TextStyle(color: Colors.white, fontSize: 17),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '公告方向：${nearest.point.directionRaw.isEmpty ? "未提供" : nearest.point.directionRaw}',
                      style: const TextStyle(color: Color(0xFFBAC8DA)),
                    ),
                  ],
                ),
              ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  _message!,
                  style: const TextStyle(color: Color(0xFFFFC89A)),
                ),
              ),
            if (_supportsBackground) ...[
              SwitchListTile(
                title: const Text(
                  '鎖定螢幕後繼續本次行程',
                  style: TextStyle(color: Colors.white),
                ),
                value: _continueInBackground,
                onChanged: _tracking || _starting || _stopping
                    ? null
                    : (value) => setState(() => _continueInBackground = value),
              ),
              SwitchListTile(
                title: const Text(
                  '語音提醒',
                  style: TextStyle(color: Colors.white),
                ),
                value: _voiceEnabled,
                onChanged: _tracking || _starting || _stopping
                    ? null
                    : (value) => setState(() => _voiceEnabled = value),
              ),
            ],
            const SizedBox(height: 22),
            SizedBox(
              height: 56,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: _tracking ? const Color(0xFFD97E77) : accent,
                  foregroundColor: const Color(0xFF102132),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                onPressed:
                    _starting ||
                        _stopping ||
                        (!_tracking && (_loading || catalog == null))
                    ? null
                    : _tracking
                    ? _stopTracking
                    : _startTracking,
                icon: Icon(
                  _tracking ? Icons.stop_rounded : Icons.navigation_rounded,
                ),
                label: Text(
                  _tracking ? '結束行車模式' : '開始行車模式',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 17,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              _loading
                  ? '正在取得官方資料…'
                  : catalog == null
                  ? '尚無可用測速資料'
                  : '警政署公開資料：${catalog.points.length} 處｜更新時間 ${catalog.generatedAt}',
              style: const TextStyle(color: Color(0xFF8FA2BA), fontSize: 12),
            ),
            const SizedBox(height: 12),
            const Text(
              '本功能使用警政署公開資料，僅供行車安全輔助。GPS 有誤差，'
              '距離與方向篩選無法排除高架、對向或平行道路。'
              '手機可在行程開始前選擇鎖屏後繼續定位。結束行程、離開此頁或關閉 App 後，請勿依賴提醒。'
              '行車請勿操作手機，請以現場標誌及法定速限為準。',
              style: TextStyle(
                color: Color(0xFF8293A8),
                height: 1.55,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
