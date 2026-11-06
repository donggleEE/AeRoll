import 'dart:async';
import 'dart:typed_data';

import 'package:aeroll/controllers/camera_session.dart';
import 'package:aeroll/models/saved_photo.dart';
import 'package:aeroll/services/photo_repository.dart';
import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_camera.dart';
import 'support/fake_photo_processor.dart';
import 'support/fake_video_processor.dart';

const front = CameraDescription(
  name: 'front',
  lensDirection: CameraLensDirection.front,
  sensorOrientation: 90,
);
Future<void> events() => Future<void>.delayed(Duration.zero);

class VideoRepository extends PhotoRepository {
  @override
  Future<SavedPhoto?> retryPreparedPhoto(String id) async => null;
  Completer<void>? gate;
  Object? error;
  int saves = 0;
  @override
  Future<SavedPhoto> saveVideo({
    required String path,
    String filterName = '원본 영상',
  }) async {
    saves++;
    await gate?.future;
    if (error != null) throw error!;
    return SavedPhoto(
      id: 'video-$saves',
      path: 'saved-video.mp4',
      createdAt: DateTime.now(),
      filterName: '원본 영상',
      isVideo: true,
    );
  }

  @override
  Future<SavedPhoto> savePhoto({
    required Uint8List bytes,
    required String filterName,
    String? captureId,
  }) async => throw UnimplementedError();
}

void main() {
  test('네이티브 녹화 정지 실패 뒤 카메라를 해제하고 복귀하면 새 녹화가 가능하다', () async {
    final made = <FakeCameraController>[];
    final session = CameraSession(
      videoProcessor: FakeVideoProcessor(),
      isSupported: true,
      photoProcessor: FakePhotoProcessor(),
      cameraLoader: () async => [testCamera],
      modeControllerFactory: (camera, audio) {
        final controller = FakeCameraController(camera)
          ..onStopVideo = () async =>
              throw CameraException('StopFailed', '정지 실패');
        made.add(controller);
        return controller;
      },
    );
    await session.initialize();
    await session.setVideoMode(true);
    await session.startVideoRecording();
    await session.suspend();
    expect(made.last.released, isTrue);
    expect(session.isRecording, isFalse);
    await session.resume();
    expect(session.canStartRecording, isTrue);
    session.dispose();
    await events();
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  test('줌 입력은 렌즈 범위로 제한하고 진행 중인 요청 뒤 최신 값만 적용한다', () async {
    final controller = FakeCameraController();
    final session = CameraSession(
      videoProcessor: FakeVideoProcessor(),
      isSupported: true,
      photoProcessor: FakePhotoProcessor(),
      cameraLoader: () async => [testCamera],
      controllerFactory: (_) => controller,
    );
    await session.initialize();
    controller.zoomCalls.clear();
    final gate = Completer<void>();
    controller.onZoom = (_) => gate.future;
    final first = session.setZoom(2);
    session.setZoom(4);
    session.setZoom(8);
    final latest = session.setZoom(3);
    expect(controller.zoomCalls, [2]);
    gate.complete();
    await first;
    await latest;
    expect(controller.zoomCalls, [2, 3]);
    expect(session.currentZoom, 3);
    controller.onZoom = null;
    await session.setZoom(100);
    expect(session.currentZoom, 100);
    expect(session.previewDigitalZoom, 12.5);
    await session.setZoom(-10);
    expect(session.currentZoom, 1);
    await session.setZoom(double.nan);
    expect(session.currentZoom, 1);
    controller.onZoom = (_) async => throw CameraException('ZoomFailed', '');
    await session.setZoom(2);
    expect(session.errorMessage, contains('배율'));
    expect(session.currentZoom, 2);
    session.dispose();
    await events();
  });
  test('렌즈 전환은 새 줌 범위를 읽고 배율을 초기화한다', () async {
    final controllers = <FakeCameraController>[];
    final session = CameraSession(
      videoProcessor: FakeVideoProcessor(),
      isSupported: true,
      photoProcessor: FakePhotoProcessor(),
      cameraLoader: () async => [testCamera, front],
      controllerFactory: (c) {
        final controller = FakeCameraController(c)
          ..zoomMax = c.lensDirection == CameraLensDirection.front ? 3 : 8;
        controllers.add(controller);
        return controller;
      },
    );
    await session.initialize();
    await session.setZoom(5);
    expect(session.currentZoom, 5);
    await session.switchCamera();
    expect(session.currentZoom, 1);
    expect(session.maxZoom, 100);
    expect(session.nativeMaxZoom, 3);
    await session.setZoom(9);
    expect(session.currentZoom, 9);
    expect(session.previewDigitalZoom, 3);
    session.dispose();
    await events();
  });
  test('사진 진입은 오디오 없이 생성하고 영상 모드에서만 오디오를 활성화한다', () async {
    final modes = <bool>[];
    final session = CameraSession(
      videoProcessor: FakeVideoProcessor(),
      isSupported: true,
      photoProcessor: FakePhotoProcessor(),
      cameraLoader: () async => [testCamera],
      modeControllerFactory: (c, a) {
        modes.add(a);
        return FakeCameraController(c);
      },
    );
    await session.initialize();
    expect(modes, [false]);
    await session.setVideoMode(true);
    expect(modes, [false, true]);
    expect(session.canStartRecording, isTrue);
    expect(session.canCapture, isFalse);
    await session.setVideoMode(false);
    expect(modes, [false, true, false]);
    expect(session.canCapture, isTrue);
    session.dispose();
    await events();
  });
  test('녹화 중 중복 시작과 모드·렌즈 전환을 막고 정지 저장을 한 번만 수행한다', () async {
    final repository = VideoRepository()..gate = Completer<void>();
    final created = <FakeCameraController>[];
    final session = CameraSession(
      videoProcessor: FakeVideoProcessor(),
      repository: repository,
      isSupported: true,
      photoProcessor: FakePhotoProcessor(),
      cameraLoader: () async => [testCamera, front],
      modeControllerFactory: (c, a) {
        final controller = FakeCameraController(c)
          ..onStopVideo = () async => XFile('missing-test-video.mp4');
        created.add(controller);
        return controller;
      },
    );
    await session.initialize();
    await session.setVideoMode(true);
    final gate = Completer<void>();
    created.last.onStartVideo = () => gate.future;
    final start = session.startVideoRecording();
    expect(session.isRecordingBusy, isTrue);
    await expectLater(
      session.startVideoRecording(),
      throwsA(isA<PhotoStorageException>()),
    );
    await events();
    gate.complete();
    await start;
    expect(session.isRecording, isTrue);
    expect(session.canSwitchCamera, isFalse);
    await expectLater(
      session.setVideoMode(false),
      throwsA(isA<PhotoStorageException>()),
    );
    await session.switchCamera();
    expect(session.isFrontCamera, isFalse);
    final stop = session.stopVideoRecording();
    final duplicate = session.stopVideoRecording();
    await events();
    expect(repository.saves, 1);
    expect(session.isRecordingBusy, isTrue);
    expect(created.last.videoStops, 1);
    repository.gate!.complete();
    final saved = await stop;
    expect(await duplicate, same(saved));
    expect(session.lastSavedVideo, same(saved));
    expect(session.isRecording, isFalse);
    expect(session.isRecordingBusy, isFalse);
    session.dispose();
    await events();
  });
  test('백그라운드는 녹화를 저장하고 dispose도 저장 완료 후 카메라를 해제한다', () async {
    for (final disposeInstead in [false, true]) {
      final repository = VideoRepository()..gate = Completer<void>();
      final created = <FakeCameraController>[];
      final session = CameraSession(
        videoProcessor: FakeVideoProcessor(),
        repository: repository,
        isSupported: true,
        photoProcessor: FakePhotoProcessor(),
        cameraLoader: () async => [testCamera],
        modeControllerFactory: (c, a) {
          final controller = FakeCameraController(c)
            ..onStopVideo = () async => XFile('missing-test-video.mp4');
          created.add(controller);
          return controller;
        },
      );
      await session.initialize();
      await session.setVideoMode(true);
      await session.startVideoRecording();
      Future<void>? suspended;
      if (disposeInstead) {
        session.dispose();
      } else {
        suspended = session.suspend();
      }
      await events();
      expect(repository.saves, 1);
      expect(created.last.released, isFalse);
      repository.gate!.complete();
      await suspended;
      await created.last.releaseDone.future.timeout(const Duration(seconds: 5));
      expect(created.last.released, isTrue);
      expect(session.lastSavedVideo?.isVideo, isTrue);
      if (!disposeInstead) {
        session.dispose();
        await events();
      }
    }
  });
  test('마이크 거부 후 사진 모드로 복구하고 영상 저장 오류를 성공으로 숨기지 않는다', () async {
    var deny = true;
    final repository = VideoRepository()
      ..error = const PhotoStorageException('영상 저장 실패');
    final session = CameraSession(
      videoProcessor: FakeVideoProcessor(),
      repository: repository,
      isSupported: true,
      photoProcessor: FakePhotoProcessor(),
      cameraLoader: () async => [testCamera],
      modeControllerFactory: (c, a) {
        return FakeCameraController(c)
          ..initializationError = (a && deny)
              ? CameraException('AudioAccessDenied', '')
              : null
          ..onStopVideo = () async => XFile('missing-test-video.mp4');
      },
    );
    await session.initialize();
    await session.setVideoMode(true);
    expect(session.errorMessage, contains('마이크'));
    expect(session.canStartRecording, isFalse);
    await session.setVideoMode(false);
    expect(session.canCapture, isTrue);
    deny = false;
    await session.setVideoMode(true);
    await session.startVideoRecording();
    await expectLater(
      session.stopVideoRecording(),
      throwsA(isA<PhotoStorageException>()),
    );
    expect(session.lastSavedVideo, isNull);
    expect(session.recoverableVideoPath, isNotNull);
    expect(session.isRecordingBusy, isFalse);
    session.dispose();
    await events();
  });
}
