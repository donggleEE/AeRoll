import 'dart:async';
import 'dart:io';

import 'package:aeroll/controllers/camera_session.dart';
import 'package:aeroll/models/film_filter.dart';
import 'package:aeroll/services/photo_repository.dart';
import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'support/fake_camera.dart';
import 'support/fake_photo_processor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('초기화 중 종료하면 늦게 준비된 카메라를 공개하지 않고 해제한다', () async {
    final controller = FakeCameraController()
      ..initialization = Completer<void>();
    final session = CameraSession(
      photoProcessor: FakePhotoProcessor(),
      isSupported: true,
      cameraLoader: () async => [testCamera],
      controllerFactory: (_) => controller,
    );
    final initializing = session.initialize();
    await Future<void>.delayed(Duration.zero);
    expect(session.isInitializing, isTrue);
    session.dispose();
    controller.initialization!.complete();
    await initializing;
    expect(session.cameraController, isNull);
    expect(controller.released, isTrue);
  });

  test('촬영 실패 후 진행 상태를 복구하고 중복 촬영을 거부한다', () async {
    final controller = FakeCameraController()..picture = Completer<XFile>();
    final session = CameraSession(
      photoProcessor: FakePhotoProcessor(),
      isSupported: true,
      cameraLoader: () async => [testCamera],
      controllerFactory: (_) => controller,
    );
    await session.initialize();
    final capture = session.capture(filter: filmFilters.first, intensity: 1);
    final failure = expectLater(capture, throwsA(isA<PhotoStorageException>()));
    expect(session.isCapturing, isTrue);
    await expectLater(
      session.capture(filter: filmFilters.last, intensity: 1),
      throwsA(isA<PhotoStorageException>()),
    );
    expect(controller.captures, 1);
    controller.picture!.completeError(CameraException('CaptureFailed', '실패'));
    await failure;
    expect(session.isCapturing, isFalse);
    expect(session.errorMessage, isNotNull);
    session.dispose();
  });

  test('suspend는 촬영 바이트를 읽기 전에 카메라를 해제하지 않는다', () async {
    final root = await Directory.systemTemp.createTemp('aeroll_session_test_');
    try {
      final source = File('${root.path}/camera.png');
      await source.writeAsBytes(
        img.encodePng(img.Image(width: 10, height: 12)),
      );
      final controller = FakeCameraController()..picture = Completer<XFile>();
      final repository = PhotoRepository(
        directoryProvider: () async => root,
        galleryWriter: (_) async {},
      );
      final session = CameraSession(
        photoProcessor: FakePhotoProcessor(),
        repository: repository,
        isSupported: true,
        cameraLoader: () async => [testCamera],
        controllerFactory: (_) => controller,
      );
      await session.initialize();
      final capture = session.capture(filter: filmFilters.first, intensity: 1);
      final suspended = session.suspend();
      await Future<void>.delayed(Duration.zero);
      expect(controller.released, isFalse);
      controller.picture!.complete(XFile(source.path));
      final saved = await capture;
      await suspended;
      expect(controller.released, isTrue);
      expect(session.cameraController, isNull);
      expect(session.isCapturing, isFalse);
      expect(saved.filterName, '원본');
      expect(await File(saved.path).exists(), isTrue);
      expect(await source.exists(), isFalse);
      session.dispose();
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('카메라 없음과 권한 거부를 사용자 오류로 제공한다', () async {
    final empty = CameraSession(
      photoProcessor: FakePhotoProcessor(),
      isSupported: true,
      cameraLoader: () async => [],
    );
    await empty.initialize();
    expect(empty.errorMessage, contains('사용 가능한 카메라'));
    empty.dispose();
    final denied = CameraSession(
      photoProcessor: FakePhotoProcessor(),
      isSupported: true,
      cameraLoader: () async => throw CameraException('CameraAccessDenied', ''),
    );
    await denied.initialize();
    expect(denied.errorMessage, contains('권한'));
    expect(denied.isInitializing, isFalse);
    denied.dispose();
  });
}
