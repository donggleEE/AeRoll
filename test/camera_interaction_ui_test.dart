import 'dart:io';
import 'dart:ui' as ui;

import 'package:aeroll/main.dart';
import 'package:aeroll/models/film_filter.dart';
import 'package:aeroll/models/saved_photo.dart';
import 'package:aeroll/widgets/camera_viewfinder.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_camera.dart';
import 'ui_checks.dart';

class InteractionSession extends ScreenSession {
  InteractionSession(FakeCameraController camera)
    : super(repository: MemoryRepository(), controller: camera);
  final focusPoints = <Offset>[];
  double? savedIntensity;
  bool supported = true, flash = false;
  @override
  bool get canSetFocus => true;
  @override
  Future<bool> focusAt(Offset point) async {
    focusPoints.add(point);
    return true;
  }

  @override
  bool get flashSupported => supported;
  @override
  bool get flashEnabled => flash;
  @override
  bool get canToggleFlash => supported;
  @override
  Future<void> setFlashEnabled(bool value) async {
    flash = value;
    notifyListeners();
  }

  @override
  Future<SavedPhoto> capture({
    required FilmFilter filter,
    required double intensity,
    double frameAspectRatio = 5 / 6,
  }) async {
    captures++;
    savedIntensity = intensity;
    return SavedPhoto(
      id: '$captures',
      path: 'missing.jpg',
      createdAt: DateTime.now(),
      filterName: filter.name,
    );
  }
}

Future<void> selectTimer(WidgetTester tester, int seconds) async {
  await tester.tap(find.byKey(const Key('capture-timer-button')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(seconds == 0 ? 'OFF' : '$seconds초').last);
  await tester.pumpAndSettle();
}

Future<void> clean(
  WidgetTester tester,
  InteractionSession session,
  FakeCameraController camera,
) async {
  await tester.pumpWidget(const SizedBox());
  session.dispose();
  await camera.dispose();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('타이머 OFF·3·5·10 선택과 재셔터 취소·정확한 한 번 촬영', (tester) async {
    screenSize(tester, const Size(390, 844));
    final camera = FakeCameraController();
    await camera.initialize();
    final session = InteractionSession(camera);
    await tester.pumpWidget(MyApp(session: session));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('capture-timer-value'))).data,
      'OFF',
    );
    for (final seconds in [3, 5, 10]) {
      await selectTimer(tester, seconds);
      await tester.tap(find.byKey(const Key('capture-button')));
      await tester.pump();
      expect(
        tester.widget<Text>(find.byKey(const Key('capture-countdown'))).data,
        '$seconds',
      );
      await tester.pump(Duration(seconds: seconds - 1));
      expect(session.captures, 0);
      await tester.tap(find.byKey(const Key('capture-button')));
      await tester.pump();
      expect(find.byKey(const Key('capture-countdown')), findsNothing);
      await tester.pump(Duration(seconds: seconds));
      expect(session.captures, 0);
    }
    await selectTimer(tester, 3);
    await tester.tap(find.byKey(const Key('capture-button')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(session.captures, 1);
    expect(find.text('사진을 기기 앨범에 저장했어요'), findsNothing);
    await tester.pump(const Duration(seconds: 10));
    expect(session.captures, 1);
    await clean(tester, session, camera);
  });

  testWidgets('백그라운드·갤러리 진입·화면 종료는 카운트다운을 취소한다', (tester) async {
    screenSize(tester, const Size(390, 844));
    final camera = FakeCameraController();
    await camera.initialize();
    final session = InteractionSession(camera);
    await tester.pumpWidget(MyApp(session: session));
    await tester.pumpAndSettle();
    await selectTimer(tester, 3);
    await tester.tap(find.byKey(const Key('capture-button')));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(seconds: 4));
    expect(session.captures, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('capture-button')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('gallery-button')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    expect(session.captures, 0);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('capture-button')));
    await tester.pump();
    await clean(tester, session, camera);
    await tester.pump(const Duration(seconds: 4));
    expect(session.captures, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('탭 초점은 표시 후 사라지고 슬라이더·버튼·줌 눈금과 충돌하지 않는다', (tester) async {
    screenSize(tester, const Size(390, 844));
    final camera = FakeCameraController();
    await camera.initialize();
    final session = InteractionSession(camera);
    await tester.pumpWidget(MyApp(session: session));
    await tester.pumpAndSettle();
    final viewport = tester.getRect(find.byKey(const Key('capture-viewport')));
    await tester.tapAt(
      viewport.topLeft + Offset(viewport.width * .3, viewport.height * .35),
    );
    await tester.pump();
    expect(session.focusPoints.length, 1);
    expect(
      tester
          .widget<AnimatedOpacity>(find.byKey(const Key('focus-indicator')))
          .opacity,
      1,
    );
    await tester.pump(const Duration(milliseconds: 1400));
    expect(
      tester
          .widget<AnimatedOpacity>(find.byKey(const Key('focus-indicator')))
          .opacity,
      0,
    );
    await tester.drag(
      find.byKey(const Key('filter-intensity-slider')),
      const Offset(-60, 0),
    );
    await tester.tap(find.byKey(const Key('camera-flash-button')));
    await tester.pump();
    expect(session.flashEnabled, isTrue);
    expect(session.focusPoints.length, 1);
    final left = await tester.startGesture(
      viewport.topLeft + Offset(viewport.width * .3, viewport.height * .4),
      pointer: 10,
    );
    final right = await tester.startGesture(
      viewport.topLeft + Offset(viewport.width * .6, viewport.height * .4),
      pointer: 11,
    );
    await left.moveBy(const Offset(-25, 0));
    await right.moveBy(const Offset(25, 0));
    await tester.pump();
    await left.moveBy(const Offset(-20, 0));
    await right.moveBy(const Offset(20, 0));
    await tester.pump();
    await left.up();
    await right.up();
    await tester.pumpAndSettle();
    expect(session.focusPoints.length, 1);
    expect(session.currentZoom, greaterThan(1));
    await session.setZoom(1);
    await tester.pump();
    final ruler = find.byKey(const Key('zoom-ruler-drag'));
    final finger = await tester.startGesture(tester.getCenter(ruler));
    await tester.pump(const Duration(seconds: 3));
    expect(session.currentZoom, 1);
    expect(
      tester
          .widget<AnimatedOpacity>(find.byKey(const Key('zoom-ruler-opacity')))
          .opacity,
      1,
    );
    await finger.moveBy(const Offset(0, -20));
    await tester.pump();
    await finger.moveBy(const Offset(0, -60));
    await tester.pump();
    expect(session.currentZoom, greaterThan(1));
    await finger.moveBy(const Offset(0, -2000));
    await tester.pump();
    expect(session.currentZoom, 100);
    await finger.moveBy(const Offset(0, 2000));
    await tester.pump();
    expect(session.currentZoom, 1);
    await finger.up();
    await tester.pump(const Duration(seconds: 2));
    expect(
      tester
          .widget<AnimatedOpacity>(find.byKey(const Key('zoom-ruler-opacity')))
          .opacity,
      0,
    );
    expect(session.focusPoints.length, 1);
    session.supported = false;
    session.notifyListeners();
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('camera-flash-button')))
          .onPressed,
      isNull,
    );
    await clean(tester, session, camera);
  });

  testWidgets('필터별 강도 기억·원본 숨김·0/50/100 미리보기와 촬영 인자 일치', (tester) async {
    screenSize(tester, const Size(390, 844));
    final camera = FakeCameraController();
    await camera.initialize();
    final session = InteractionSession(camera);
    final captureKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: MyApp(session: session),
      ),
    );
    await tester.pumpAndSettle();
    for (final intensity in [0.0, .5, 1.0]) {
      tester
          .widget<Slider>(find.byKey(const Key('filter-intensity-slider')))
          .onChanged!(intensity);
      await tester.pump();
      expect(
        tester
            .widget<CameraViewfinder>(find.byType(CameraViewfinder))
            .intensity,
        intensity,
      );
      await tester.tap(find.byKey(const Key('capture-button')));
      await tester.pump();
      expect(session.savedIntensity, intensity);
      await tester.pump(const Duration(milliseconds: 100));
    }
    tester
        .widget<Slider>(find.byKey(const Key('filter-intensity-slider')))
        .onChanged!(.5);
    await tester.pump();
    await tester.tap(find.byKey(const Key('filter-warm')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Slider>(find.byKey(const Key('filter-intensity-slider')))
          .value,
      1,
    );
    await tester.tap(find.byKey(const Key('filter-cold')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Slider>(find.byKey(const Key('filter-intensity-slider')))
          .value,
      .5,
    );
    final boundary =
        captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory('build').create(recursive: true);
      await File('build/camera_controls_ui.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    await tester.tap(find.byKey(const Key('filter-original')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('filter-intensity-slider')), findsNothing);
    await clean(tester, session, camera);
  });
}
