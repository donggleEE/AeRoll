import 'dart:async';
import 'dart:math' as math;

import 'package:aeroll/controllers/level_controller.dart';
import 'package:aeroll/widgets/camera_level_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sensors_plus/sensors_plus.dart';

AccelerometerEvent gravity(double degrees) => AccelerometerEvent(
  math.sin(degrees * math.pi / 180) * 9.8,
  math.cos(degrees * math.pi / 180) * 9.8,
  0,
  DateTime.now(),
);
void main() {
  test('수평계 토글과 앱 수명주기에 맞춰 센서 구독을 열고 닫는다', () async {
    var listens = 0, cancels = 0;
    final stream = StreamController<AccelerometerEvent>.broadcast(
      sync: true,
      onListen: () => listens++,
      onCancel: () => cancels++,
    );
    final controller = LevelController(streamFactory: () => stream.stream);
    expect(controller.enabled, isFalse);
    expect(listens, 0);
    await controller.setEnabled(true);
    expect(listens, 1);
    stream.add(gravity(1.5));
    expect(controller.isAvailable, isTrue);
    expect(controller.angleDegrees, closeTo(1.5, .0001));
    await controller.suspend();
    expect(cancels, 1);
    expect(controller.angleDegrees, isNull);
    stream.add(gravity(20));
    expect(controller.isAvailable, isFalse);
    await controller.resume();
    expect(listens, 2);
    stream.add(gravity(-2));
    expect(controller.angleDegrees, closeTo(-2, .0001));
    await controller.setEnabled(false);
    expect(cancels, 2);
    await controller.setEnabled(true);
    controller.dispose();
    expect(cancels, 3);
    await stream.close();
  });
  testWidgets('평평한 자세와 오류 및 오래된 센서를 유효한 수평으로 처리하지 않는다', (tester) async {
    final stream = StreamController<AccelerometerEvent>.broadcast(sync: true);
    final controller = LevelController(streamFactory: () => stream.stream);
    await controller.setEnabled(true);
    stream.add(gravity(0));
    expect(controller.isAvailable, isTrue);
    stream.add(AccelerometerEvent(0, 0, 9.8, DateTime.now()));
    expect(controller.isAvailable, isFalse);
    expect(controller.angleDegrees, isNull);
    stream.add(gravity(0));
    stream.addError(StateError('센서 오류'));
    expect(controller.isAvailable, isFalse);
    stream.add(gravity(0));
    await tester.pump(const Duration(milliseconds: 1100));
    expect(controller.isAvailable, isFalse);
    controller.dispose();
    await stream.close();
  });
  testWidgets('수평계는 양쪽 2도 경계까지 노란색이고 무효 값은 중립이다', (tester) async {
    for (final angle in [-2.0, 2.0, 2.01]) {
      await tester.pumpWidget(
        MaterialApp(
          home: CameraLevelIndicator(angleDegrees: angle, isAvailable: true),
        ),
      );
      final text = tester.widget<Text>(find.byKey(const Key('level-angle')));
      expect(
        text.style!.color,
        angle.abs() <= 2 ? Colors.yellow : Colors.white,
      );
    }
    await tester.pumpWidget(
      const MaterialApp(
        home: CameraLevelIndicator(angleDegrees: 0, isAvailable: false),
      ),
    );
    expect(find.text('기기를 세워 주세요'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('level-angle'))).style!.color,
      Colors.white,
    );
  });
}
