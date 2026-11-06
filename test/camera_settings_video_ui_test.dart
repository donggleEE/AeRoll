import 'dart:async';

import 'package:aeroll/controllers/level_controller.dart';
import 'package:aeroll/main.dart';
import 'package:aeroll/models/saved_photo.dart';
import 'package:aeroll/screens/gallery_screen.dart';
import 'package:aeroll/screens/video_detail_screen.dart';
import 'package:aeroll/widgets/camera_viewfinder.dart';
import 'package:aeroll/widgets/camera_level_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'support/fake_camera.dart';
import 'ui_checks.dart';

Future<void> finish(
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
  testWidgets('가로 화면에서 중력의 90도 방향을 수평으로 보정한다', (tester) async {
    screenSize(tester, const Size(844, 390));
    final camera = FakeCameraController();
    await camera.initialize();
    final session = ScreenSession(
      repository: MemoryRepository(),
      controller: camera,
    );
    final events = StreamController<AccelerometerEvent>.broadcast(sync: true);
    final level = LevelController(streamFactory: () => events.stream);
    await level.setEnabled(true);
    await tester.pumpWidget(MyApp(session: session, levelController: level));
    events.add(AccelerometerEvent(9.8, 0, 0, DateTime.now()));
    await tester.pump();
    final indicator = tester.widget<CameraLevelIndicator>(
      find.byType(CameraLevelIndicator),
    );
    expect(indicator.isAvailable, isTrue);
    expect(indicator.angleDegrees, closeTo(0, .0001));
    level.dispose();
    await events.close();
    await finish(tester, session, camera);
  });
  testWidgets('한 손가락 이동은 줌하지 않고 두 손가락 핀치는 배율을 변경한다', (tester) async {
    screenSize(tester, const Size(390, 844));
    final camera = FakeCameraController();
    await camera.initialize();
    final session = ScreenSession(
      repository: MemoryRepository(),
      controller: camera,
    );
    await tester.pumpWidget(MyApp(session: session));
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(150, 250), const Offset(40, 40));
    await tester.pumpAndSettle();
    expect(session.zoomRequests, isEmpty);
    final first = await tester.startGesture(const Offset(120, 250), pointer: 1);
    final second = await tester.startGesture(
      const Offset(250, 250),
      pointer: 2,
    );
    await tester.pump();
    await first.moveTo(const Offset(90, 250));
    await second.moveTo(const Offset(280, 250));
    await tester.pump();
    await first.moveTo(const Offset(60, 250));
    await second.moveTo(const Offset(310, 250));
    await tester.pump();
    await first.up();
    await second.up();
    await tester.pumpAndSettle();
    expect(session.zoomRequests, isNotEmpty);
    expect(session.currentZoom, greaterThan(1));
    expect(session.currentZoom, lessThanOrEqualTo(session.maxZoom));
    await finish(tester, session, camera);
  });
  testWidgets('설정 시트의 격자와 수평계 토글이 실제 미리보기에 반영된다', (tester) async {
    screenSize(tester, const Size(390, 844));
    final camera = FakeCameraController();
    await camera.initialize();
    final session = ScreenSession(
      repository: MemoryRepository(),
      controller: camera,
    );
    final level = LevelController(streamFactory: () => const Stream.empty());
    await tester.pumpWidget(MyApp(session: session, levelController: level));
    await tester.pumpAndSettle();
    expect(
      tester.widget<CameraViewfinder>(find.byType(CameraViewfinder)).showGrid,
      isTrue,
    );
    expect(find.byKey(const Key('level-indicator')), findsNothing);
    await tester.tap(find.byKey(const Key('camera-settings-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('grid-switch')));
    await tester.tap(find.byKey(const Key('level-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('설정 닫기'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<CameraViewfinder>(find.byType(CameraViewfinder)).showGrid,
      isFalse,
    );
    expect(level.enabled, isTrue);
    expect(find.byKey(const Key('level-indicator')), findsOneWidget);
    await finish(tester, session, camera);
    level.dispose();
  });
  for (final item in [('wide', 9 / 16), ('classic', 3 / 4), ('square', 1.0)]) {
    testWidgets('${item.$1} 사진 비율이 검정 여백 안에 표시되고 같은 비율로 촬영한다', (tester) async {
      screenSize(tester, const Size(390, 844));
      final camera = FakeCameraController();
      await camera.initialize();
      final session = ScreenSession(
        repository: MemoryRepository(),
        controller: camera,
      );
      await tester.pumpWidget(MyApp(session: session));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('camera-settings-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('ratio-${item.$1}')));
      await tester.tap(find.byTooltip('설정 닫기'));
      await tester.pumpAndSettle();
      final viewport = tester.getRect(
        find.byKey(const Key('capture-viewport')),
      );
      expect(viewport.width / viewport.height, closeTo(item.$2, .0001));
      expect(viewport.top, greaterThan(0));
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor,
        Colors.black,
      );
      await tester.tap(find.byKey(const Key('capture-button')));
      await tester.pump();
      expect(session.capturedRatio, closeTo(item.$2, .0001));
      session.finishAcquisition();
      session.pending.completeError(StateError('테스트 저장 중단'));
      await tester.pumpAndSettle();
      await finish(tester, session, camera);
    });
  }
  testWidgets('영상 필터를 녹화 시작에 고정하고 녹화 타이머·정지·조작 잠금을 제공한다', (tester) async {
    screenSize(tester, const Size(390, 844));
    final camera = FakeCameraController();
    await camera.initialize();
    final session = ScreenSession(
      repository: MemoryRepository(),
      controller: camera,
    );
    await tester.pumpWidget(MyApp(session: session));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('video-mode-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('video-filter-notice')), findsOneWidget);
    expect(find.byKey(const Key('filter-warm')), findsOneWidget);
    await tester.tap(find.byKey(const Key('filter-warm')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CameraViewfinder>(find.byType(CameraViewfinder))
          .enableFilter,
      isTrue,
    );
    await tester.tap(find.byKey(const Key('capture-button')));
    await tester.pump(const Duration(seconds: 2));
    expect(session.videoStarts, 1);
    expect(session.recordedFilter?.id, 'warm');
    expect(
      tester.widget<InkWell>(find.byKey(const Key('filter-warm'))).onTap,
      isNull,
    );
    expect(find.byKey(const Key('recording-timer')), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('camera-settings-button')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('switch-camera-button')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('photo-mode-button')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const Key('capture-button')));
    await tester.pumpAndSettle();
    expect(session.videoStops, 1);
    expect(find.byKey(const Key('recording-timer')), findsNothing);
    await tester.tap(find.byKey(const Key('photo-mode-button')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CameraViewfinder>(find.byType(CameraViewfinder))
          .enableFilter,
      isTrue,
    );
    await finish(tester, session, camera);
  });
  testWidgets('혼합 갤러리에서 영상은 재생 화면으로 열리고 재생 실패를 안내한다', (tester) async {
    final video = SavedPhoto(
      id: 'v1',
      path: 'missing-test-video.mp4',
      createdAt: DateTime.now(),
      filterName: '원본 영상',
      isVideo: true,
      isInDeviceAlbum: false,
    );
    final repository = MemoryRepository()..items = [video];
    await tester.pumpWidget(
      MaterialApp(home: GalleryScreen(repository: repository)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('video-tile-v1')), findsOneWidget);
    await tester.tap(find.byKey(const Key('video-tile-v1')));
    await tester.pumpAndSettle();
    expect(find.byType(VideoDetailScreen), findsOneWidget);
    expect(find.byKey(const Key('video-error')), findsOneWidget);
    expect(find.textContaining('앱 사본'), findsOneWidget);
  });
  testWidgets('영상 뷰어 초기화 실패에 재시도 버튼을 제공한다', (tester) async {
    var attempts = 0;
    final video = SavedPhoto(
      id: 'v',
      path: 'missing.mp4',
      createdAt: DateTime.now(),
      filterName: '원본 영상',
      isVideo: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: VideoDetailScreen(
          video: video,
          controllerFactory: (_) {
            attempts++;
            throw StateError('지원하지 않는 형식');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('video-error')), findsOneWidget);
    await tester.tap(find.text('다시 불러오기'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
  });
}
