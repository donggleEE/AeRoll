import 'dart:async';

import 'package:aeroll/controllers/camera_session.dart';
import 'package:aeroll/main.dart';
import 'package:aeroll/models/film_filter.dart';
import 'package:aeroll/models/saved_photo.dart';
import 'package:aeroll/screens/gallery_screen.dart';
import 'package:aeroll/services/photo_repository.dart';
import 'package:aeroll/widgets/camera_viewfinder.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_camera.dart';
import 'support/fake_photo_processor.dart';

class MemoryRepository extends PhotoRepository {
  Object? error;
  List<SavedPhoto> items = [];
  @override
  Future<List<SavedPhoto>> listPhotos() async {
    if (error != null) throw error!;
    return items;
  }
}

class ScreenSession extends CameraSession {
  ScreenSession({required MemoryRepository repository, this.controller})
    : super(repository: repository, photoProcessor: FakePhotoProcessor());
  final FakeCameraController? controller;
  final pending = Completer<SavedPhoto>();
  int captures = 0, suspends = 0, resumes = 0, switches = 0, saves = 0;
  bool capturing = false, front = false;
  bool video = false, recording = false, recordingBusy = false;
  int videoStarts = 0, videoStops = 0;
  FilmFilter? recordedFilter;
  double zoom = 1;
  final zoomRequests = <double>[];
  double? capturedRatio;
  @override
  CameraController? get cameraController => controller;
  @override
  String? get errorMessage => controller == null ? '카메라 권한을 허용해 주세요' : null;
  @override
  bool get isCapturing => capturing;
  @override
  bool get isFrontCamera => front;
  @override
  bool get canSwitchCamera =>
      controller != null && !capturing && !recording && !recordingBusy;
  @override
  bool get canCapture =>
      controller != null && !capturing && saves < 3 && !video;
  @override
  bool get videoMode => video;
  @override
  bool get isRecording => recording;
  @override
  bool get isRecordingBusy => recordingBusy;
  @override
  bool get canStartRecording =>
      controller != null && video && !recording && !recordingBusy;
  @override
  double get currentZoom => zoom;
  @override
  double get minZoom => 1;
  @override
  double get maxZoom => 100;
  @override
  double get nativeMaxZoom => 8;
  @override
  double get previewDigitalZoom => (zoom / 8).clamp(1.0, 100.0);
  @override
  Future<void> setZoom(double value) async {
    zoom = value;
    zoomRequests.add(value);
    notifyListeners();
  }

  @override
  Future<void> setVideoMode(bool value) async {
    video = value;
    notifyListeners();
  }

  @override
  Future<void> startVideoRecording({
    FilmFilter filter = const FilmFilter(id: 'original', name: '원본'),
    double intensity = 1,
  }) async {
    recordedFilter = filter;
    recording = true;
    videoStarts++;
    notifyListeners();
  }

  @override
  Future<SavedPhoto> stopVideoRecording() async {
    recording = false;
    videoStops++;
    notifyListeners();
    return SavedPhoto(
      id: 'test-video',
      path: 'missing-ui-video.mp4',
      createdAt: DateTime.now(),
      filterName: '원본 영상',
      isVideo: true,
    );
  }

  @override
  int get pendingSaves => saves;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> suspend() async {
    suspends++;
  }

  @override
  Future<void> resume() async {
    resumes++;
  }

  @override
  Future<void> switchCamera() async {
    switches++;
    front = !front;
    notifyListeners();
  }

  void finishAcquisition() {
    capturing = false;
    saves++;
    notifyListeners();
  }

  @override
  Future<SavedPhoto> capture({
    required FilmFilter filter,
    required double intensity,
    double frameAspectRatio = 5 / 6,
  }) {
    captures++;
    capturedRatio = frameAspectRatio;
    capturing = true;
    notifyListeners();
    return pending.future.whenComplete(() {
      saves--;
      notifyListeners();
    });
  }
}

void screenSize(WidgetTester tester, Size size, {double textScale = 1}) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
}

void main() {
  testWidgets('하단 반투명 조작부는 시스템 여백을 포함해 화면 3분의 1보다 작다', (tester) async {
    screenSize(tester, const Size(360, 640));
    addTearDown(tester.view.resetPadding);
    final session = ScreenSession(repository: MemoryRepository());
    await tester.pumpWidget(MyApp(session: session));
    await tester.pumpAndSettle();
    final panel = find.byKey(const Key('camera-controls-panel'));
    for (final bottom in [0.0, 34.0]) {
      tester.view.padding = FakeViewPadding(bottom: bottom);
      await tester.pumpAndSettle();
      expect(tester.getSize(panel).height, lessThan(640 / 3));
      expect(tester.widget<ColoredBox>(panel).color.a, closeTo(.28, .001));
      expect(find.byKey(const Key('selected-filter-name')), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('capture-button')))
            .tooltip,
        '사진 촬영',
      );
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
    session.dispose();
    await tester.pumpAndSettle();
  });
  testWidgets('0 및 좁은 초기 화면에서 정상 전체 화면으로 복구한다', (tester) async {
    screenSize(tester, Size.zero);
    final session = ScreenSession(repository: MemoryRepository());
    await tester.pumpWidget(MyApp(session: session));
    await tester.pump();
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(24, 844);
    await tester.pump();
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    expect(find.text('카메라 권한을 허용해 주세요'), findsOneWidget);
    final viewport = tester.getSize(find.byType(CameraViewfinder));
    expect(viewport.width, 390);
    expect(viewport.width / viewport.height, closeTo(9 / 16, .0001));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
    await tester.pumpAndSettle();
  });
  testWidgets('같은 예시 이미지에 warm cold 변환과 선택 테두리를 표시한다', (tester) async {
    screenSize(tester, const Size(390, 844));
    final session = ScreenSession(repository: MemoryRepository());
    await tester.pumpWidget(MyApp(session: session));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('capture-button')))
          .onPressed,
      isNull,
    );
    for (final filter in filmFilters) {
      final images = tester.widgetList<Image>(
        find.descendant(
          of: find.byKey(Key('filter-${filter.id}')),
          matching: find.byType(Image),
        ),
      );
      final assets = images
          .map((image) {
            final provider = image.image;
            return (provider is ResizeImage ? provider.imageProvider : provider)
                as AssetImage;
          })
          .map((asset) => asset.assetName)
          .toList();
      expect(assets, contains(samplePhotoAsset));
      expect(assets, [samplePhotoAsset]);
      expect(
        find.descendant(
          of: find.byKey(Key('filter-${filter.id}')),
          matching: find.byType(ColorFiltered),
        ),
        filter.isOriginal ? findsNothing : findsOneWidget,
      );
    }
    await tester.tap(find.byKey(const Key('filter-warm')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('selected-filter-name'))).data,
      'warm',
    );
    final selected = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byKey(const Key('filter-warm')),
        matching: find.byType(AnimatedContainer),
      ),
    );
    expect(
      ((selected.decoration as BoxDecoration).border as Border).top.color,
      Colors.white,
    );
    await tester.pumpWidget(const SizedBox());
    session.dispose();
    await tester.pumpAndSettle();
  });
  testWidgets('취득 즉시 피드백 후 저장 중에도 셔터가 다시 활성화되고 실패를 알린다', (tester) async {
    screenSize(tester, const Size(390, 844));
    final controller = FakeCameraController();
    await controller.initialize();
    final session = ScreenSession(
      repository: MemoryRepository(),
      controller: controller,
    );
    await tester.pumpWidget(MyApp(session: session));
    await tester.pumpAndSettle();
    final capture = find.byKey(const Key('capture-button'));
    await tester.tap(capture);
    await tester.pump();
    expect(session.captures, 1);
    expect(session.capturedRatio, closeTo(9 / 16, .0001));
    expect(
      tester
          .widget<AnimatedOpacity>(find.byKey(const Key('shutter-flash')))
          .opacity,
      greaterThan(0),
    );
    expect(tester.widget<IconButton>(capture).onPressed, isNull);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('switch-camera-button')))
          .onPressed,
      isNull,
    );
    session.finishAcquisition();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('저장 중 1'), findsOneWidget);
    expect(tester.widget<IconButton>(capture).onPressed, isNotNull);
    expect(find.text('사진을 기기 앨범에 저장했어요'), findsNothing);
    session.pending.completeError(const PhotoStorageException('권한 거부'));
    await tester.pumpAndSettle();
    expect(find.textContaining('사진을 저장하지 못했어요'), findsOneWidget);
    expect(tester.widget<IconButton>(capture).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
    await tester.pumpAndSettle();
    await controller.dispose();
  });
  testWidgets('전환 버튼은 선택 렌즈에 따라 접근성 설명을 변경한다', (tester) async {
    screenSize(tester, const Size(390, 844));
    final controller = FakeCameraController();
    await controller.initialize();
    final session = ScreenSession(
      repository: MemoryRepository(),
      controller: controller,
    );
    await tester.pumpWidget(MyApp(session: session));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('switch-camera-button')));
    await tester.pumpAndSettle();
    expect(session.switches, 1);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('switch-camera-button')))
          .tooltip,
      '후면 카메라로 전환',
    );
    await tester.pumpWidget(const SizedBox());
    session.dispose();
    await tester.pumpAndSettle();
    await controller.dispose();
  });
  testWidgets('작은 화면 갤러리에서 돌아오면 카메라를 복구한다', (tester) async {
    screenSize(tester, const Size(320, 568));
    final session = ScreenSession(repository: MemoryRepository());
    await tester.pumpWidget(MyApp(session: session));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('gallery-button')));
    await tester.pumpAndSettle();
    expect(find.text('첫 번째 순간을 담아볼까요?'), findsOneWidget);
    expect(session.suspends, 1);
    await tester.tap(find.text('사진 찍으러 가기'));
    await tester.pumpAndSettle();
    expect(find.byType(GalleryScreen), findsNothing);
    expect(session.resumes, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
    await tester.pumpAndSettle();
  });
  testWidgets('320x568 두 배 글자 크기에서도 레이아웃 오류가 없다', (tester) async {
    screenSize(tester, const Size(320, 568), textScale: 2);
    final session = ScreenSession(repository: MemoryRepository());
    await tester.pumpWidget(MyApp(session: session));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byKey(const Key('capture-button')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
    await tester.pumpAndSettle();
  });
  testWidgets('갤러리 조회 실패 후 재시도하면 빈 상태로 회복한다', (tester) async {
    final repository = MemoryRepository()
      ..error = const PhotoStorageException('읽기 실패');
    await tester.pumpWidget(
      MaterialApp(home: GalleryScreen(repository: repository)),
    );
    await tester.pumpAndSettle();
    expect(find.text('사진을 불러오지 못했어요'), findsOneWidget);
    repository.error = null;
    await tester.tap(find.text('다시 불러오기'));
    await tester.pumpAndSettle();
    expect(find.text('첫 번째 순간을 담아볼까요?'), findsOneWidget);
  });
}
