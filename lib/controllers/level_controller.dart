import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// 기기의 세로축에 대한 중력 방향. 화면 회전 보정은 표시 계층에서 수행한다.
class LevelController extends ChangeNotifier {
  LevelController({Stream<AccelerometerEvent> Function()? streamFactory})
    : _streamFactory = streamFactory ?? _events;

  static Stream<AccelerometerEvent> _events() => accelerometerEventStream(
    samplingPeriod: const Duration(milliseconds: 100),
  );

  final Stream<AccelerometerEvent> Function() _streamFactory;
  StreamSubscription<AccelerometerEvent>? _subscription;
  Timer? _staleTimer;
  bool _enabled = false;
  bool get enabled => _enabled;
  bool _available = false;
  bool get isAvailable => _available;
  double? _angle;
  double? get angleDegrees => _angle;
  bool _active = true;
  bool _disposed = false;
  int _generation = 0;

  Future<void> setEnabled(bool enabled) async {
    if (_disposed) return;
    _enabled = enabled;
    await _updateSubscription();
  }

  Future<void> suspend() async {
    _active = false;
    await _updateSubscription();
  }

  Future<void> resume() async {
    _active = true;
    await _updateSubscription();
  }

  Future<void> _updateSubscription() async {
    final generation = ++_generation;
    final old = _subscription;
    _subscription = null;
    _staleTimer?.cancel();
    _invalidate();
    await old?.cancel();
    if (_disposed || generation != _generation || !_active || !_enabled) return;
    try {
      _subscription = _streamFactory().listen(
        (event) {
          if (_disposed || generation != _generation) return;
          _staleTimer?.cancel();
          _staleTimer = Timer(const Duration(seconds: 1), _invalidate);
          final magnitude = math.sqrt(
            event.x * event.x + event.y * event.y + event.z * event.z,
          );
          final projection = math.sqrt(event.x * event.x + event.y * event.y);
          // 평평하게 놓거나 중력 방향을 신뢰할 수 없는 경우 수평이라고 표시하지 않는다.
          if (!magnitude.isFinite ||
              magnitude < 3 ||
              magnitude > 18 ||
              projection / magnitude < .25) {
            _invalidate();
            return;
          }
          _angle = math.atan2(event.x, event.y) * 180 / math.pi;
          _available = true;
          notifyListeners();
        },
        onError: (Object _) {
          if (!_disposed && generation == _generation) _invalidate();
        },
        onDone: () {
          if (!_disposed && generation == _generation) _invalidate();
        },
      );
    } catch (_) {
      _invalidate();
    }
  }

  void _invalidate() {
    _available = false;
    _angle = null;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _staleTimer?.cancel();
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
