import 'package:aeroll/main.dart';
import 'package:aeroll/widgets/camera_viewfinder.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_camera.dart';
import 'ui_checks.dart';

GestureDetector gesture(WidgetTester tester) => tester.widget<GestureDetector>(
  find.byKey(const Key('viewfinder-zoom-gesture')),
);
double target(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(find.byKey(const Key('zoom-ruler-opacity')))
    .opacity;
Future<void> cleanup(
  WidgetTester tester,
  ScreenSession session,
  FakeCameraController camera,
) async {
  await tester.pumpWidget(const SizedBox());
  session.dispose();
  await tester.pumpAndSettle();
  await camera.dispose();
}

void main() {
  testWidgets('줌 눈금은 핀치 종료 2초 뒤 300ms 동안 페이드한다', (tester) async {
    screenSize(tester, const Size(390, 844));
    final camera = FakeCameraController();
    await camera.initialize();
    final session = ScreenSession(
      repository: MemoryRepository(),
      controller: camera,
    );
    await tester.pumpWidget(MyApp(session: session));
    await tester.pumpAndSettle();
    expect(target(tester), 0);
    gesture(tester).onScaleStart!(ScaleStartDetails(pointerCount: 2));
    await tester.pumpAndSettle();
    expect(target(tester), 1);
    await tester.pump(const Duration(seconds: 3));
    expect(target(tester), 1);
    gesture(tester).onScaleEnd!(ScaleEndDetails());
    await tester.pump(const Duration(milliseconds: 1999));
    expect(target(tester), 1);
    await tester.pump(const Duration(milliseconds: 1));
    expect(target(tester), 0);
    final render = tester.renderObject<RenderAnimatedOpacity>(
      find.byKey(const Key('zoom-ruler-opacity')),
    );
    expect(render.opacity.value, greaterThan(0));
    await tester.pump(const Duration(milliseconds: 300));
    expect(render.opacity.value, closeTo(0, .0001));
    await cleanup(tester, session, camera);
  });
  testWidgets('새 핀치는 숨김 예약을 취소하고 화면 종료는 타이머를 정리한다', (tester) async {
    screenSize(tester, const Size(390, 844));
    final camera = FakeCameraController();
    await camera.initialize();
    final session = ScreenSession(
      repository: MemoryRepository(),
      controller: camera,
    );
    await tester.pumpWidget(MyApp(session: session));
    await tester.pumpAndSettle();
    gesture(tester).onScaleStart!(ScaleStartDetails(pointerCount: 2));
    gesture(tester).onScaleEnd!(ScaleEndDetails());
    await tester.pump(const Duration(milliseconds: 1500));
    gesture(tester).onScaleStart!(ScaleStartDetails(pointerCount: 2));
    await tester.pump(const Duration(seconds: 3));
    expect(target(tester), 1);
    gesture(tester).onScaleEnd!(ScaleEndDetails());
    await cleanup(tester, session, camera);
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
  });
  testWidgets('디지털 확대는 카메라에 적용하고 고정 RGB 변환의 계수는 바꾸지 않는다', (tester) async {
    screenSize(tester, const Size(390, 844));
    final camera = FakeCameraController();
    await camera.initialize();
    final session = ScreenSession(
      repository: MemoryRepository(),
      controller: camera,
    );
    await tester.pumpWidget(MyApp(session: session));
    await tester.pumpAndSettle();
    final viewfinder = find.byType(CameraViewfinder);
    final colorEffect = find.descendant(
      of: viewfinder,
      matching: find.byType(ColorFiltered),
    );
    final before = tester.widget<ColorFiltered>(colorEffect).colorFilter;
    await session.setZoom(80);
    await tester.pump();
    final raw = find.byKey(const Key('camera-digital-zoom'));
    final transform = tester.widget<Transform>(raw);
    expect(transform.transform.entry(0, 0), 10);
    expect(
      find.descendant(of: raw, matching: find.byType(Image)),
      findsNothing,
    );
    expect(
      find.descendant(of: raw, matching: find.byType(CameraPreview)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: viewfinder, matching: find.byType(Image)),
      findsNothing,
    );
    expect(colorEffect, findsOneWidget);
    expect(tester.widget<ColorFiltered>(colorEffect).colorFilter, before);
    expect(
      tester.widget<ColorFiltered>(colorEffect).colorFilter,
      ColorFilter.matrix(
        tester
            .widget<CameraViewfinder>(viewfinder)
            .filter
            .transform
            .colorMatrix,
      ),
    );
    await cleanup(tester, session, camera);
  });
}
