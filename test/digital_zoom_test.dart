import 'dart:async';
import 'dart:typed_data';

import 'package:aeroll/controllers/camera_session.dart';
import 'package:aeroll/models/film_filter.dart';
import 'package:aeroll/models/saved_photo.dart';
import 'package:aeroll/services/photo_compositor.dart';
import 'package:aeroll/services/photo_processor.dart';
import 'package:aeroll/services/photo_repository.dart';
import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'support/fake_camera.dart';
import 'support/fake_photo_processor.dart';
import 'support/fake_video_processor.dart';

class MediaRepository extends PhotoRepository {
  @override
  Future<SavedPhoto?> retryPreparedPhoto(String id) async => null;
  int photos = 0, videos = 0;
  @override
  Future<SavedPhoto> savePhoto({
    required Uint8List bytes,
    required String filterName,
    String? captureId,
  }) async {
    photos++;
    return SavedPhoto(
      id: 'p',
      path: 'p.jpg',
      createdAt: DateTime.now(),
      filterName: filterName,
    );
  }

  @override
  Future<SavedPhoto> saveVideo({
    required String path,
    String filterName = '원본 영상',
  }) async {
    videos++;
    return SavedPhoto(
      id: 'v',
      path: 'v.mp4',
      createdAt: DateTime.now(),
      filterName: filterName,
      isVideo: true,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('논리 배율은 즉시 100배까지 바뀌고 네이티브 응답 전에도 검정 축소가 없다', () async {
    final camera = FakeCameraController();
    final session = CameraSession(
      captureStore: MemoryPhotoCaptureStore(),
      isSupported: true,
      photoProcessor: FakePhotoProcessor(),
      cameraLoader: () async => [testCamera],
      controllerFactory: (_) => camera,
    );
    await session.initialize();
    final gate = Completer<void>();
    camera.onZoom = (_) => gate.future;
    final zoom = session.setZoom(100);
    expect(session.currentZoom, 100);
    expect(session.previewDigitalZoom, 100);
    gate.complete();
    await zoom;
    expect(camera.zoomCalls.last, 8);
    expect(session.previewDigitalZoom, 12.5);
    final lower = Completer<void>();
    camera.onZoom = (_) => lower.future;
    final back = session.setZoom(1);
    expect(session.previewDigitalZoom, 1);
    lower.complete();
    await back;
    expect(session.currentZoom, 1);
    expect(session.previewDigitalZoom, 1);
    session.dispose();
    await Future<void>.delayed(Duration.zero);
  });
  test('0.6배는 지원 렌즈에서만 제공하고 기본은 항상 1배다', () async {
    for (final minimum in [.3, .6, 1.0]) {
      final camera = FakeCameraController()..zoomMin = minimum;
      final session = CameraSession(
        captureStore: MemoryPhotoCaptureStore(),
        isSupported: true,
        photoProcessor: FakePhotoProcessor(),
        cameraLoader: () async => [testCamera],
        controllerFactory: (_) => camera,
      );
      await session.initialize();
      expect(session.currentZoom, 1);
      expect(session.maxZoom, 100);
      expect(session.minZoom, minimum < .6 ? .6 : minimum);
      await session.setZoom(.6);
      expect(session.currentZoom, session.minZoom);
      expect(session.previewDigitalZoom, greaterThanOrEqualTo(1));
      session.dispose();
      await Future<void>.delayed(Duration.zero);
    }
  });
  test('사진은 촬영 순간 추가 디지털 배율을 고정해 처리기에 전달한다', () async {
    final camera = FakeCameraController()..picture = Completer<XFile>();
    final processor = FakePhotoProcessor();
    final session = CameraSession(
      captureStore: MemoryPhotoCaptureStore(),
      repository: MediaRepository(),
      isSupported: true,
      photoProcessor: processor,
      cameraLoader: () async => [testCamera],
      controllerFactory: (_) => camera,
    );
    await session.initialize();
    await session.setZoom(24);
    final shot = session.capture(filter: filmFilters.last, intensity: 1);
    await Future<void>.delayed(Duration.zero);
    await session.setZoom(100);
    camera.picture!.complete(
      XFile.fromData(Uint8List.fromList([1]), name: 'shot'),
    );
    await shot;
    expect(processor.digitalScales, [3]);
    expect(session.currentZoom, 24);
    session.dispose();
    await Future<void>.delayed(Duration.zero);
  });
  test('사진 디지털 크롭 뒤 고정 RGB 변환을 적용하고 출력 크기를 유지한다', () {
    final base = img.Image(width: 200, height: 200);
    img.fill(base, color: img.ColorRgb8(200, 0, 0));
    img.fillRect(
      base,
      x1: 90,
      y1: 90,
      x2: 109,
      y2: 109,
      color: img.ColorRgb8(0, 0, 220),
    );
    final result = img.decodePng(
      compositePhoto(
        photoBytes: Uint8List.fromList(img.encodePng(base)),
        filterId: 'warm',
        lossless: true,
        frameAspectRatio: 1,
        digitalScale: 10,
      ),
    )!;
    expect((result.width, result.height), (200, 200));
    for (final x in [10, 100, 190]) {
      final pixel = result.getPixel(x, 100);
      expect([
        pixel.r,
        pixel.g,
        pixel.b,
      ], filmFilters[1].transform.applyReferenceRgb8(0, 0, 220));
    }
    final tiny = img.decodeJpg(
      compositePhoto(
        photoBytes: Uint8List.fromList(
          img.encodePng(img.Image(width: 10, height: 12)),
        ),
        digitalScale: 100,
      ),
    )!;
    expect((tiny.width, tiny.height), (10, 12));
  });
  test('영구 이미지 처리기는 디지털 배율을 전달하고 직접 합성과 일치한다', () async {
    final worker = PhotoProcessor();
    try {
      final base = img.Image(width: 100, height: 120);
      img.fill(base, color: img.ColorRgb8(200, 0, 0));
      img.fillRect(
        base,
        x1: 40,
        y1: 48,
        x2: 59,
        y2: 71,
        color: img.ColorRgb8(0, 0, 220),
      );
      final bytes = Uint8List.fromList(img.encodePng(base));
      final actual = await worker.process(
        photoBytes: bytes,
        intensity: 1,
        frameAspectRatio: 5 / 6,
        mirrorHorizontally: false,
        digitalScale: 5,
      );
      expect(actual, compositePhoto(photoBytes: bytes, digitalScale: 5));
    } finally {
      await worker.dispose();
    }
  });
  test('녹화는 네이티브 기준 줌을 고정하고 필터·추가 줌 타임라인을 출력 후 저장한다', () async {
    final made = <FakeCameraController>[];
    final exporter = FakeVideoProcessor()..gate = Completer<void>();
    final repository = MediaRepository();
    final session = CameraSession(
      captureStore: MemoryPhotoCaptureStore(),
      repository: repository,
      isSupported: true,
      photoProcessor: FakePhotoProcessor(),
      videoProcessor: exporter,
      cameraLoader: () async => [testCamera],
      controllerFactory: (c) {
        final camera = FakeCameraController(c)
          ..zoomMin = .6
          ..onStopVideo = () async => XFile('');
        made.add(camera);
        return camera;
      },
    );
    await session.initialize();
    await session.setVideoMode(true);
    await session.setZoom(6);
    await session.startVideoRecording(filter: filmFilters.last, intensity: .5);
    expect(made.last.zoomCalls.last, .6);
    final nativeCalls = made.last.zoomCalls.length;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await session.setZoom(12);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await session.setZoom(100);
    expect(made.last.zoomCalls.length, nativeCalls);
    final saved = session.stopVideoRecording();
    await Future<void>.delayed(Duration.zero);
    expect(session.isVideoProcessing, isTrue);
    expect(repository.videos, 0);
    expect(exporter.selectedFilter?.id, 'cold');
    expect(exporter.selectedIntensity, .5);
    expect(exporter.frames.first.timeMs, 0);
    expect(exporter.frames.first.digitalScale, closeTo(10, .0001));
    expect(exporter.frames.last.digitalScale, closeTo(100 / .6, .0001));
    exporter.gate!.complete();
    final result = await saved;
    expect(result.filterName, 'cold 영상');
    expect(repository.videos, 1);
    expect(exporter.successfulSaves, 1);
    session.dispose();
    await Future<void>.delayed(Duration.zero);
  });
  test('영상 출력 실패는 원본으로 대신 저장하지 않고 복구 경로를 보존한다', () async {
    final exporter = FakeVideoProcessor()
      ..error = const PhotoStorageException('영상 출력 실패');
    final repository = MediaRepository();
    final session = CameraSession(
      captureStore: MemoryPhotoCaptureStore(),
      repository: repository,
      isSupported: true,
      photoProcessor: FakePhotoProcessor(),
      videoProcessor: exporter,
      cameraLoader: () async => [testCamera],
      controllerFactory: (c) =>
          FakeCameraController(c)..onStopVideo = () async => XFile(''),
    );
    await session.initialize();
    await session.setVideoMode(true);
    await session.startVideoRecording(filter: filmFilters.last);
    await expectLater(
      session.stopVideoRecording(),
      throwsA(isA<PhotoStorageException>()),
    );
    expect(repository.videos, 0);
    expect(session.lastSavedVideo, isNull);
    expect(session.recoverableVideoPath, 'recoverable.mp4');
    expect(session.isVideoProcessing, isFalse);
    expect(exporter.successfulSaves, 0);
    session.dispose();
    await Future<void>.delayed(Duration.zero);
  });
}
