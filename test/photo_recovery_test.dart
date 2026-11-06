import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aeroll/controllers/camera_session.dart';
import 'package:aeroll/models/film_filter.dart';
import 'package:aeroll/services/photo_capture_store.dart';
import 'package:aeroll/services/photo_repository.dart';
import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_camera.dart';
import 'support/fake_photo_processor.dart';

class FailingBackupStore extends PhotoCaptureStore {
  FailingBackupStore(Future<Directory> Function() provider)
    : super(directoryProvider: provider);
  bool fail = true;
  @override
  Future<void> stage(PhotoCaptureJob job, Uint8List bytes) async {
    if (fail) {
      fail = false;
      throw const FileSystemException('원본 보관 실패');
    }
    await super.stage(job, bytes);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(
    () async =>
        root = await Directory.systemTemp.createTemp('aeroll_recovery_'),
  );
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('원본과 촬영 설정은 재시작 뒤 복구하고 처리 전 사진을 성공 목록에 넣지 않는다', () async {
    final store = PhotoCaptureStore(directoryProvider: () async => root);
    final job = store.create({
      'filterId': 'cold',
      'intensity': .5,
      'digitalScale': 3,
    });
    await store.stage(job, Uint8List.fromList([1, 2, 3]));
    final recovered = await PhotoCaptureStore(
      directoryProvider: () async => root,
    ).pending();
    expect(recovered.single.settings, job.settings);
    expect(await store.read(recovered.single), [1, 2, 3]);
    final repository = PhotoRepository(directoryProvider: () async => root);
    expect(await repository.listPhotos(), isEmpty);
    await store.complete(job);
    expect(await store.pending(), isEmpty);
  });

  test('복구 디렉터리 초기화 실패가 다음 보관 재시도를 영구 차단하지 않는다', () async {
    var attempts = 0;
    final store = PhotoCaptureStore(
      directoryProvider: () async {
        if (attempts++ == 0) throw const FileSystemException('공간 부족');
        return root;
      },
    );
    final job = store.create({'filterId': 'original'});
    await expectLater(
      store.stage(job, Uint8List.fromList([1])),
      throwsA(isA<FileSystemException>()),
    );
    await store.stage(job, Uint8List.fromList([1]));
    expect((await store.pending()).single.id, job.id);
    await store.complete(job);
  });

  test('캡처 후 셔터를 재개하고 앨범 실패를 재시작 후 JPEG 재처리 없이 재시도한다', () async {
    final store = PhotoCaptureStore(directoryProvider: () async => root);
    final source = File('${root.path}/camera.jpg');
    await source.writeAsBytes([10, 20, 30]);
    final albumGate = Completer<void>();
    var calls = 0;
    final repository = PhotoRepository(
      directoryProvider: () async => root,
      galleryWriter: (_) async {
        calls++;
        await albumGate.future;
      },
    );
    final camera = FakeCameraController()
      ..onPicture = () async => XFile(source.path);
    final processor = FakePhotoProcessor();
    final session = CameraSession(
      repository: repository,
      captureStore: store,
      photoProcessor: processor,
      isSupported: true,
      cameraLoader: () async => [testCamera],
      controllerFactory: (_) => camera,
    );
    await session.initialize();
    final shot = session.capture(filter: filmFilters.last, intensity: .5);
    final failed = expectLater(shot, throwsA(isA<PhotoStorageException>()));
    while (calls == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(session.canCapture, isTrue);
    expect(session.pendingSaves, 1);
    expect(await repository.listPhotos(), isEmpty);
    expect((await store.pending()).single.settings['intensity'], .5);
    albumGate.completeError(const PhotoStorageException('앨범 실패'));
    await failed;
    expect(session.recoverablePhotoCount, 1);
    expect(await repository.listPhotos(), isEmpty);
    final id = (await store.pending()).single.id;
    expect(session.photoTimings[id]!['captureReady'], isNotNull);
    session.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final nextProcessor = FakePhotoProcessor();
    final nextRepository = PhotoRepository(
      directoryProvider: () async => root,
      galleryWriter: (path) async {
        calls++;
        expect(await File(path).readAsBytes(), [10, 20, 30]);
      },
    );
    final next = CameraSession(
      repository: nextRepository,
      captureStore: PhotoCaptureStore(directoryProvider: () async => root),
      photoProcessor: nextProcessor,
      isSupported: true,
      cameraLoader: () async => [testCamera],
      controllerFactory: (_) => FakeCameraController(),
    );
    await next.initialize();
    expect(next.recoverablePhotoCount, 1);
    await next.retryFailedPhotos();
    expect(next.recoverablePhotoCount, 0);
    expect(nextProcessor.calls, isEmpty);
    expect((await nextRepository.listPhotos()).single.id, id);
    expect(await store.pending(), isEmpty);
    expect(calls, 2);
    next.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 10));
  });

  test('앨범 완료 뒤 원본 정리만 남은 작업은 같은 ID로 중복 저장하지 않는다', () async {
    var writes = 0;
    final repository = PhotoRepository(
      directoryProvider: () async => root,
      galleryWriter: (_) async {
        writes++;
      },
    );
    final store = PhotoCaptureStore(directoryProvider: () async => root);
    final job = store.create({'filterId': 'original'});
    await store.stage(job, Uint8List.fromList([1]));
    final saved = await repository.savePhoto(
      bytes: Uint8List.fromList([9]),
      filterName: '원본',
      captureId: job.id,
    );
    final recovered = await repository.retryPreparedPhoto(job.id);
    expect(recovered!.id, saved.id);
    expect(writes, 1);
    await store.complete(job);
  });

  test('원본 영구 보관 실패에도 카메라 파일을 삭제하지 않고 같은 설정으로 재시도한다', () async {
    final source = File('${root.path}/temporary.jpg');
    await source.writeAsBytes([1, 2, 3]);
    final store = FailingBackupStore(() async => root);
    final processor = FakePhotoProcessor();
    final session = CameraSession(
      captureStore: store,
      photoProcessor: processor,
      repository: PhotoRepository(
        directoryProvider: () async => root,
        galleryWriter: (_) async {},
      ),
      isSupported: true,
      cameraLoader: () async => [testCamera],
      controllerFactory: (_) =>
          FakeCameraController()..onPicture = () async => XFile(source.path),
    );
    await session.initialize();
    await expectLater(
      session.capture(filter: filmFilters[1], intensity: .25),
      throwsA(isA<PhotoStorageException>()),
    );
    expect(await source.exists(), isTrue);
    expect(session.recoverablePhotoCount, 1);
    expect(processor.calls, isEmpty);
    await session.retryFailedPhotos();
    expect(session.recoverablePhotoCount, 0);
    expect(processor.calls.single.intensity, .25);
    expect(processor.calls.single.filterId, 'warm');
    session.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 10));
  });
}
