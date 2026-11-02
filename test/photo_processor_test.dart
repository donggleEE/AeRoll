import 'dart:io';
import 'dart:typed_data';

import 'package:aeroll/models/film_filter.dart';
import 'package:aeroll/services/photo_compositor.dart';
import 'package:aeroll/services/photo_processor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('전체 화면 비율로 중앙 자르고 전면 원본만 반전한 뒤 필터를 합성한다', () {
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
    final overlay = img.Image(width: 120, height: 120, numChannels: 4);
    img.fillRect(
      overlay,
      x1: 0,
      y1: 0,
      x2: 29,
      y2: 119,
      color: img.ColorRgba8(0, 220, 0, 255),
    );
    final result = img.decodeJpg(
      compositePhoto(
        photoBytes: Uint8List.fromList(img.encodePng(base)),
        overlayBytes: Uint8List.fromList(img.encodePng(overlay)),
        frameAspectRatio: 1,
        mirrorHorizontally: true,
      ),
    )!;
    expect(result.getPixel(10, 60).g, closeTo(220, 4));
    expect(result.getPixel(40, 60).b, closeTo(220, 4));
    expect(result.getPixel(100, 60).r, closeTo(220, 4));
    final tall = img.decodeJpg(
      compositePhoto(
        photoBytes: Uint8List.fromList(img.encodePng(base)),
        frameAspectRatio: .5,
      ),
    )!;
    expect((tall.width, tall.height), (60, 120));
    for (final ratio in [0.0, -1.0, double.nan, double.infinity]) {
      expect(
        () => compositePhoto(
          photoBytes: Uint8List.fromList(img.encodePng(base)),
          frameAspectRatio: ratio,
        ),
        throwsArgumentError,
      );
    }
  });
  test('사전 로딩한 필터를 여러 번 재사용해도 직접 합성과 픽셀이 일치한다', () async {
    final worker = PhotoProcessor();
    try {
      await worker.preload();
      final base = img.Image(width: 100, height: 120);
      img.fill(base, color: img.ColorRgb8(90, 100, 110));
      final bytes = Uint8List.fromList(img.encodePng(base));
      for (final filter in filmFilters.where(
        (filter) => filter.assetPath != null,
      )) {
        for (final strength in [.5, 1.0, 1.0]) {
          final output = await worker.process(
            photoBytes: bytes,
            overlayAsset: filter.assetPath,
            intensity: strength,
            frameAspectRatio: 5 / 6,
            mirrorHorizontally: false,
          );
          final direct = compositePhoto(
            photoBytes: bytes,
            overlayBytes: File(filter.assetPath!).readAsBytesSync(),
            intensity: strength,
          );
          expect(output, direct);
        }
      }
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
