import 'dart:async';

import 'package:aeroll/controllers/camera_session.dart';
import 'package:aeroll/services/photo_repository.dart';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_camera.dart';
import 'support/fake_photo_processor.dart';

const front = CameraDescription(
  name: 'front',
  lensDirection: CameraLensDirection.front,
  sensorOrientation: 270,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  CameraSession create(FakeCameraController controller, {bool flash = true}) =>
      CameraSession(
        isSupported: true,
        photoProcessor: FakePhotoProcessor(),
        cameraLoader: () async => [controller.description],
        controllerFactory: (_) => controller,
        flashSupportLoader: (_) async => flash,
      );

  test('기본 플래시는 OFF이며 ON은 torch 대신 촬영 발광 모드를 사용한다', () async {
    final controller = FakeCameraController();
    final session = create(controller);
    await session.initialize();
    expect(session.flashSupported, isTrue);
    expect(session.flashEnabled, isFalse);
    expect(controller.flashCalls, [FlashMode.off]);
    await session.setFlashEnabled(true);
    expect(session.flashEnabled, isTrue);
    expect(controller.flashCalls.last, FlashMode.always);
    await session.setFlashEnabled(false);
    expect(session.flashEnabled, isFalse);
    expect(controller.flashCalls, [
      FlashMode.off,
      FlashMode.always,
      FlashMode.off,
    ]);
    expect(controller.flashCalls, isNot(contains(FlashMode.torch)));
    session.dispose();
  });

  test('플래시 미지원은 비활성화하고 지원 카메라도 설정 실패를 숨기지 않는다', () async {
    final unsupported = create(FakeCameraController(), flash: false);
    await unsupported.initialize();
    expect(unsupported.canToggleFlash, isFalse);
    await expectLater(
      unsupported.setFlashEnabled(true),
      throwsA(isA<PhotoStorageException>()),
    );
    unsupported.dispose();

    final controller = FakeCameraController();
    final session = create(controller);
    await session.initialize();
    controller.onFlash = (_) async =>
        throw CameraException('unsupported', 'Flash is not supported');
    await expectLater(
      session.setFlashEnabled(true),
      throwsA(isA<PhotoStorageException>()),
    );
    expect(session.flashEnabled, isFalse);
    expect(session.flashSupported, isFalse);
    expect(session.isFlashBusy, isFalse);
    session.dispose();
  });

  test('플래시 전환 중에는 중복 설정과 UI 촬영을 잠그고 복귀 때 선택값을 복원한다', () async {
    final cameras = <FakeCameraController>[];
    final session = CameraSession(
      isSupported: true,
      photoProcessor: FakePhotoProcessor(),
      cameraLoader: () async => [testCamera],
      controllerFactory: (_) {
        final controller = FakeCameraController();
        cameras.add(controller);
        return controller;
      },
      flashSupportLoader: (_) async => true,
    );
    await session.initialize();
    final gate = Completer<void>();
    cameras.first.onFlash = (_) => gate.future;
    final setting = session.setFlashEnabled(true);
    expect(session.isFlashBusy, isTrue);
    expect(session.canToggleFlash, isFalse);
    expect(session.canCapture, isFalse);
    gate.complete();
    await setting;
    await session.suspend();
    await session.resume();
    expect(cameras.length, 2);
    expect(session.flashEnabled, isTrue);
    expect(cameras.last.flashCalls, [FlashMode.off, FlashMode.always]);
    session.dispose();
  });

  test('렌즈별 실제 지원을 따르고 전면의 가짜 플래시를 만들지 않는다', () async {
    final controllers = <FakeCameraController>[];
    final session = CameraSession(
      isSupported: true,
      photoProcessor: FakePhotoProcessor(),
      cameraLoader: () async => [testCamera, front],
      controllerFactory: (description) {
        final controller = FakeCameraController(description);
        controllers.add(controller);
        return controller;
      },
      flashSupportLoader: (description) async =>
          description.name == testCamera.name,
    );
    await session.initialize();
    await session.setFlashEnabled(true);
    await session.switchCamera();
    expect(session.isFrontCamera, isTrue);
    expect(session.flashSupported, isFalse);
    expect(session.flashEnabled, isFalse);
    expect(controllers.last.flashCalls, [FlashMode.off]);
    await session.switchCamera();
    expect(session.flashEnabled, isTrue);
    session.dispose();
  });

  test('정규화한 미리보기 초점 좌표를 회전·반전 중복 없이 그대로 전달한다', () async {
    final controller = FakeCameraController(front);
    final session = create(controller);
    await session.initialize();
    expect(session.canSetFocus, isTrue);
    const point = Offset(.15, .8);
    expect(await session.focusAt(point), isTrue);
    expect(controller.focusModeCalls, [FocusMode.auto]);
    expect(controller.focusCalls, [point]);
    for (final invalid in [
      const Offset(-.1, .5),
      const Offset(.5, 1.1),
      const Offset(double.nan, .5),
    ]) {
      await expectLater(
        session.focusAt(invalid),
        throwsA(isA<PhotoStorageException>()),
      );
    }
    expect(controller.focusCalls.length, 1);
    await session.suspend();
    expect(await session.focusAt(point), isFalse);
    session.dispose();
  });

  test('초점 미지원과 실패는 성공 표시하지 않고 다음 요청은 복구한다', () async {
    final fixed = FakeCameraController()..focusPointSupported = false;
    final unsupported = create(fixed);
    await unsupported.initialize();
    expect(unsupported.canSetFocus, isFalse);
    expect(await unsupported.focusAt(const Offset(.5, .5)), isFalse);
    expect(fixed.focusCalls, isEmpty);
    unsupported.dispose();

    final controller = FakeCameraController();
    final session = create(controller);
    await session.initialize();
    controller.onFocus = (_) async => throw CameraException('focusFailed', '');
    await expectLater(
      session.focusAt(const Offset(.2, .7)),
      throwsA(isA<PhotoStorageException>()),
    );
    controller.onFocus = null;
    expect(await session.focusAt(const Offset(.7, .2)), isTrue);
    session.dispose();
  });

  test('실제 capability 채널은 선택 카메라 ID로 조회하고 조회 실패는 지원으로 오인하지 않는다', () async {
    const channel = MethodChannel('aeroll/camera_capabilities');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'hasFlash');
      expect(call.arguments, {'cameraName': testCamera.name});
      return true;
    });
    final session = CameraSession(
      isSupported: true,
      photoProcessor: FakePhotoProcessor(),
      cameraLoader: () async => [testCamera],
      controllerFactory: (_) => FakeCameraController(),
    );
    await session.initialize();
    expect(session.flashSupported, isTrue);
    session.dispose();
    messenger.setMockMethodCallHandler(channel, null);
    final missing = CameraSession(
      isSupported: true,
      photoProcessor: FakePhotoProcessor(),
      cameraLoader: () async => [testCamera],
      controllerFactory: (_) => FakeCameraController(),
    );
    await missing.initialize();
    expect(missing.flashSupported, isFalse);
    expect(missing.canCapture, isTrue);
    missing.dispose();
  });
}
