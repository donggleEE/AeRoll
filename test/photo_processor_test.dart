import 'dart:typed_data';
import 'dart:async';

import 'package:aeroll/models/film_filter.dart';
import 'package:aeroll/services/photo_compositor.dart';
import 'package:aeroll/services/photo_processor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('실제 worker 처리 중 주 isolate 타이머가 응답하고 단계별 시간이 돌아온다', () async {
    final source = img.Image(width: 1200, height: 1600);
    img.fill(source, color: img.ColorRgb8(100, 140, 200));
    final bytes = Uint8List.fromList(img.encodeJpg(source, quality: 95));
    final worker = PhotoProcessor();
    await worker.preload();
    var beats = 0;
    final timer = Timer.periodic(
      const Duration(milliseconds: 1),
      (_) => beats++,
    );
    try {
      final result = await worker.process(
        photoBytes: bytes,
        filterId: 'cold',
        intensity: .5,
        frameAspectRatio: 3 / 4,
        mirrorHorizontally: false,
      );
      expect(result, isNotEmpty);
      expect(beats, greaterThan(1));
      expect(
        worker.lastTimings.keys,
        containsAll([
          'decode',
          'orientation',
          'cropResize',
          'filter',
          'thumbnail',
          'encode',
        ]),
      );
      final thumbnail = img.decodeJpg(worker.lastThumbnailBytes!)!;
      expect(thumbnail.height, 120);
    } finally {
      timer.cancel();
      await worker.dispose();
    }
  });
  test('중앙 크롭과 전면 반전을 RGB 변환보다 먼저 수행한다', () {
    final base = img.Image(width: 120, height: 120);
    img.fill(base, color: img.ColorRgb8(220, 0, 0));
    img.fillRect(
      base,
      x1: 60,
      y1: 0,
      x2: 119,
      y2: 119,
      color: img.ColorRgb8(0, 0, 220),
    );
    final bytes = Uint8List.fromList(img.encodePng(base));
    final result = img.decodePng(
      compositePhoto(
        photoBytes: bytes,
        filterId: 'warm',
        frameAspectRatio: 1,
        mirrorHorizontally: true,
        lossless: true,
      ),
    )!;
    final left = result.getPixel(10, 60), right = result.getPixel(100, 60);
    expect([
      left.r,
      left.g,
      left.b,
    ], filmFilters[1].transform.applyReferenceRgb8(0, 0, 220));
    expect([
      right.r,
      right.g,
      right.b,
    ], filmFilters[1].transform.applyReferenceRgb8(220, 0, 0));
    final tall = img.decodePng(
      compositePhoto(photoBytes: bytes, frameAspectRatio: .5, lossless: true),
    )!;
    expect((tall.width, tall.height), (60, 120));
    for (final ratio in [0.0, -1.0, double.nan, double.infinity]) {
      expect(
        () => compositePhoto(photoBytes: bytes, frameAspectRatio: ratio),
        throwsArgumentError,
      );
    }
  });

  test('같은 입력의 미리보기 RGB와 isolate 저장 PNG가 픽셀 단위로 일치한다', () async {
    final worker = PhotoProcessor();
    try {
      await worker.preload();
      final source = img.Image(width: 100, height: 120, numChannels: 4);
      for (final pixel in source) {
        pixel.setRgba(pixel.x * 2, pixel.y * 2, (pixel.x + pixel.y) % 256, 255);
      }
      final bytes = Uint8List.fromList(img.encodePng(source));
      for (final filter in [
        filmFilters[1],
        filmFilters[2],
        filmFilters[1],
        filmFilters[0],
      ]) {
        for (final intensity in [0.0, .5, 1.0]) {
          final output = await worker.process(
            photoBytes: bytes,
            filterId: filter.id,
            intensity: intensity,
            frameAspectRatio: 5 / 6,
            mirrorHorizontally: false,
            lossless: true,
          );
          final preview = filter.transform.applyToImage(
            img.decodePng(bytes)!,
            intensity: intensity,
          );
          final saved = img.decodePng(output)!;
          expect(saved.getBytes(), preview.getBytes());
          expect(
            output,
            compositePhoto(
              photoBytes: bytes,
              filterId: filter.id,
              lossless: true,
              intensity: intensity,
            ),
          );
        }
      }
      expect(img.decodePng(bytes)!.getBytes(), source.getBytes());
    } finally {
      await worker.dispose();
    }
  });

  test('처리 오류가 다음 작업을 막지 않고 종료 중 요청도 끝난다', () async {
    final worker = PhotoProcessor();
    await expectLater(
      worker.process(
        photoBytes: Uint8List(0),
        intensity: 1,
        frameAspectRatio: 1,
        mirrorHorizontally: false,
      ),
      throwsStateError,
    );
    final bytes = Uint8List.fromList(
      img.encodePng(img.Image(width: 10, height: 12)),
    );
    final pending = worker.process(
      photoBytes: bytes,
      intensity: 1,
      frameAspectRatio: 1,
      mirrorHorizontally: false,
    );
    final completed = pending.then((_) => true, onError: (Object _) => false);
    await worker.dispose().timeout(const Duration(seconds: 5));
    await completed.timeout(const Duration(seconds: 5));
    await expectLater(
      worker.process(
        photoBytes: bytes,
        intensity: 1,
        frameAspectRatio: 1,
        mirrorHorizontally: false,
      ),
      throwsStateError,
    );
  });
}
