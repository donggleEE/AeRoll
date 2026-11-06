import 'dart:typed_data';

import 'package:aeroll/services/photo_compositor.dart' as current;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'support/legacy_photo_pipeline.dart' as legacy;

void main() {
  test('복사·버퍼 최적화 전후 JPEG와 PNG는 방향·반전·크롭·줌·강도별로 같다', () {
    for (final orientation in [1, 2, 6, 8]) {
      final image = img.Image(width: 80, height: 96, numChannels: 4);
      for (final p in image) {
        p.setRgba(p.x * 3, p.y * 2, (p.x + p.y) % 256, 255);
      }
      image.exif.imageIfd.orientation = orientation;
      final input = Uint8List.fromList(img.encodeJpg(image, quality: 95));
      for (final id in ['original', 'warm', 'cold']) {
        for (final intensity in [0.0, .5, 1.0]) {
          for (final lossless in [true, false]) {
            final expected = legacy.compositePhoto(
              photoBytes: input,
              filterId: id,
              intensity: intensity,
              lossless: lossless,
              frameAspectRatio: 3 / 4,
              mirrorHorizontally: true,
              digitalScale: 2,
            );
            final actual = current.compositePhoto(
              photoBytes: input,
              filterId: id,
              intensity: intensity,
              lossless: lossless,
              frameAspectRatio: 3 / 4,
              mirrorHorizontally: true,
              digitalScale: 2,
            );
            expect(
              actual,
              expected,
              reason: '$orientation/$id/$intensity/$lossless',
            );
          }
        }
      }
    }
  });

  test('썸네일 생성은 최종 출력 해상도·필터·메타데이터를 변경하지 않는다', () {
    final image = img.Image(width: 700, height: 840);
    img.fill(image, color: img.ColorRgb8(40, 120, 200));
    final input = Uint8List.fromList(img.encodePng(image));
    Uint8List? thumbnail;
    final withThumbnail = current.compositePhoto(
      photoBytes: input,
      filterId: 'cold',
      intensity: .5,
      onThumbnail: (bytes) => thumbnail = bytes,
    );
    final expected = legacy.compositePhoto(
      photoBytes: input,
      filterId: 'cold',
      intensity: .5,
    );
    expect(withThumbnail, expected);
    final small = img.decodeJpg(thumbnail!)!;
    expect(small.width, lessThanOrEqualTo(120));
    expect(small.height, 120);
    final saved = img.decodeJpg(withThumbnail)!;
    expect((saved.width, saved.height), (700, 840));
  });
}
