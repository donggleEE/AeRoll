import 'dart:async';
import 'dart:typed_data';

import 'package:aeroll/controllers/camera_session.dart';
import 'package:aeroll/models/film_filter.dart';
import 'package:aeroll/models/saved_photo.dart';
import 'package:aeroll/services/photo_repository.dart';
import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_camera.dart';
import 'support/fake_photo_processor.dart';

const frontCamera = CameraDescription(
  name: 'front',
  lensDirection: CameraLensDirection.front,
  sensorOrientation: 90,
);

class GatedRepository extends PhotoRepository {
  final jobs = <Completer<void>>[];
  final filters = <String>[];
  @override
  Future<SavedPhoto> savePhoto({
    required Uint8List bytes,
    required String filterName,
  }) async {
    filters.add(filterName);
    final gate = Completer<void>();
    jobs.add(gate);
    await gate.future;
    return SavedPhoto(
      id: '${jobs.length}',
      path: 'fake.jpg',
      createdAt: DateTime.now(),
      filterName: filterName,
    );
  }
}

Future<void> settleEvents() => Future<void>.delayed(Duration.zero);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('전후면 전환과 복귀 렌즈를 유지하고 단일 렌즈는 안전하게 거부한다', () async {
    final made = <FakeCameraController>[];
    final session = CameraSession(
      isSupported: true,
      photoProcessor: FakePhotoProcessor(),
      cameraLoader: () async => [testCamera, frontCamera],
      controllerFactory: (c) {
        final controller = FakeCameraController(c);
        made.add(controller);
        return controller;
      },
    );
    await session.initialize();
    expect(session.isFrontCamera, isFalse);
    expect(session.canSwitchCamera, isTrue);
    await session.switchCamera();
    expect(session.isFrontCamera, isTrue);
    expect(made.first.released, isTrue);
    await session.suspend();
    await session.resume();
    expect(session.isFrontCamera, isTrue);
    await session.switchCamera();
    expect(session.isFrontCamera, isFalse);
    session.dispose();
    await settleEvents();
    final single = CameraSession(
      isSupported: true,
      photoProcessor: FakePhotoProcessor(),
      cameraLoader: () async => [testCamera],
      controllerFactory: (_) => FakeCameraController(),
    );
    await single.initialize();
    expect(single.canSwitchCamera, isFalse);
    await single.switchCamera();
    expect(single.isFrontCamera, isFalse);
    single.dispose();
    await settleEvents();
  });
  test('센서 취득 중 전환을 막고 저장 대기는 최대 3장으로 제한한다', () async {
    final repository = GatedRepository();
    final processor = FakePhotoProcessor();
    final controllers = <FakeCameraController>[];
    final session = CameraSession(
      repository: repository,
      photoProcessor: processor,
      isSupported: true,
      cameraLoader: () async => [testCamera, frontCamera],
      controllerFactory: (c) {
        final controller = FakeCameraController(c)
          ..onPicture = () async =>
              XFile.fromData(Uint8List.fromList([1]), name: 'shot');
        controllers.add(controller);
        return controller;
      },
    );
    await session.initialize();
    controllers.last.picture = Completer<XFile>();
    controllers.last.onPicture = null;
    final first = session.capture(
      filter: filmFilters[1],
      intensity: .5,
      frameAspectRatio: .5,
    );
    expect(session.isCapturing, isTrue);
    expect(session.canSwitchCamera, isFalse);
    await session.switchCamera();
    expect(session.isFrontCamera, isFalse);
    controllers.last.picture!.complete(
      XFile.fromData(Uint8List.fromList([1]), name: 'shot'),
    );
    await settleEvents();
    expect(session.isCapturing, isFalse);
    expect(session.pendingSaves, 1);
    expect(session.canCapture, isTrue);
    await session.switchCamera();
    expect(session.isFrontCamera, isTrue);
    final second = session.capture(
      filter: filmFilters[2],
      intensity: 1,
      frameAspectRatio: .6,
    );
    await settleEvents();
    final third = session.capture(filter: filmFilters[0], intensity: 1);
    await settleEvents();
    expect(session.pendingSaves, 3);
    expect(session.canCapture, isFalse);
    expect(repository.jobs.length, 1);
    await expectLater(
      session.capture(filter: filmFilters.first, intensity: 1),
      throwsA(isA<PhotoStorageException>()),
    );
    repository.jobs[0].complete();
    await first;
    await settleEvents();
    expect(session.canCapture, isTrue);
    expect(repository.jobs.length, 2);
    repository.jobs[1].complete();
    await second;
    await settleEvents();
    repository.jobs[2].complete();
    await third;
    await settleEvents();
    expect(repository.filters, ['라이트', '콜드', '원본']);
    expect(session.pendingSaves, 0);
    expect(processor.calls[0], (
      asset: filmFilters[1].assetPath,
      intensity: .5,
      ratio: .5,
      mirror: false,
    ));
    expect(processor.calls[1].mirror, isTrue);
    expect(processor.calls[1].ratio, .6);
    expect(session.lastCaptureDuration, isNotNull);
    expect(session.lastSaveDuration, isNotNull);
    session.dispose();
    await settleEvents();
  });
  test('실패한 저장 뒤 다음 작업을 처리하고 종료 시 대기열을 비운 뒤 처리기를 닫는다', () async {
    final repository = GatedRepository();
    final processor = FakePhotoProcessor();
    final controller = FakeCameraController()
      ..onPicture = () async =>
          XFile.fromData(Uint8List.fromList([1]), name: 'shot');
    final session = CameraSession(
      repository: repository,
      photoProcessor: processor,
      isSupported: true,
      cameraLoader: () async => [testCamera],
      controllerFactory: (_) => controller,
    );
    await session.initialize();
    final first = session.capture(filter: filmFilters.first, intensity: 1);
    final failure = expectLater(first, throwsA(isA<PhotoStorageException>()));
    await settleEvents();
    final second = session.capture(filter: filmFilters.last, intensity: 1);
    await settleEvents();
    session.dispose();
    await settleEvents();
    expect(processor.closed, isFalse);
    repository.jobs.first.completeError(const PhotoStorageException('저장 실패'));
    await failure;
    await settleEvents();
    expect(repository.jobs.length, 2);
    repository.jobs.last.complete();
    await second;
    await settleEvents();
    await settleEvents();
    expect(session.pendingSaves, 0);
    expect(processor.closed, isTrue);
    expect(controller.released, isTrue);
  });
}
