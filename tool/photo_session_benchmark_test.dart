import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aeroll/controllers/camera_session.dart';
import 'package:aeroll/models/film_filter.dart';
import 'package:aeroll/models/saved_photo.dart';
import 'package:aeroll/services/photo_capture_store.dart';
import 'package:aeroll/services/photo_processor.dart';
import 'package:aeroll/services/photo_repository.dart';
import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/fake_camera.dart';

/// Windows 파일 I/O와 실제 처리 isolate를 사용한다. 센서·기기 앨범·FPS 측정이 아니다.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('12MP 연속 세 장의 단계별 후처리·파일 I/O·주 isolate 응답을 기록한다', () async {
    final fixture = File('build/photo_latency_input.jpg');
    if (!await fixture.exists()) {
      throw StateError(
        '먼저 dart run tool/photo_latency_benchmark.dart prepare 실행',
      );
    }
    final root = await Directory.systemTemp.createTemp('aeroll_session_bench_');
    final album = await Directory('${root.path}/album_stub').create();
    var sequence = 0;
    final processor = PhotoProcessor();
    final camera = FakeCameraController()
      ..onPicture = () async {
        final file = await fixture.copy(
          '${root.path}/sensor_stub_${sequence++}.jpg',
        );
        return XFile(file.path);
      };
    final session = CameraSession(
      isSupported: true,
      cameraLoader: () async => [testCamera],
      controllerFactory: (_) => camera,
      photoProcessor: processor,
      captureStore: PhotoCaptureStore(directoryProvider: () async => root),
      repository: PhotoRepository(
        directoryProvider: () async => root,
        galleryWriter: (path) async {
          await File(path)
              .copy('${album.path}/${File(path).uri.pathSegments.last}');
        },
      ),
    );
    final watch = Stopwatch();
    var beats = 0, previous = 0, maxGap = 0;
    Timer? timer;
    try {
      await session.initialize();
      await processor.preload();
      watch.start();
      timer = Timer.periodic(const Duration(milliseconds: 10), (_) {
        final now = watch.elapsedMicroseconds;
        final gap = now - previous;
        if (gap > maxGap) maxGap = gap;
        previous = now;
        beats++;
      });
      final shots = <Future<SavedPhoto>>[];
      for (var n = 0; n < 3; n++) {
        session.notePhotoInput();
        shots.add(
          session.capture(
            filter: filmFilters.last,
            intensity: .5,
            frameAspectRatio: 4 / 3,
          ),
        );
        while (session.isCapturing) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      }
      expect(session.pendingSaves, 3);
      expect(session.canCapture, isFalse);
      // 카메라 화면을 떠나도 확보한 세 원본의 저장을 계속한다.
      await session.suspend();
      final saved = await Future.wait(shots);
      expect(saved.length, 3);
      expect(await album.list().length, 3);
      expect(session.recoverablePhotoCount, 0);
      final report = {
        'environment': 'Windows / Flutter test / 12MP / cold 50% / 1배 / JPEG95',
        'limitations':
            '센서는 파일 복사 대역, 앨범도 파일 복사 대역. 실제 캡처·권한·MediaStore·FPS·UI 프레임 측정 아님.',
        'unit': 'microseconds',
        'shots': session.photoTimings,
        'mainHeartbeats10ms': beats,
        'maxHeartbeatGapUs': maxGap,
        'maxRssBytes': ProcessInfo.maxRss,
      };
      final text = const JsonEncoder.withIndent('  ').convert(report);
      await File('build/photo_session_profile.json').writeAsString(text);
      stdout.writeln(text);
    } finally {
      timer?.cancel();
      session.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await root.delete(recursive: true);
    }
  });
}
