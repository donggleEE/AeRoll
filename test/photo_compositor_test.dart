import 'dart:typed_data';

import 'package:aeroll/models/filter_transform.dart';
import 'package:aeroll/services/photo_compositor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

Uint8List png(int width, int height, List<int> rgba) {
  final image = img.Image(width: width, height: height, numChannels: 4);
  img.fill(image, color: img.ColorRgba8(rgba[0], rgba[1], rgba[2], rgba[3]));
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  test('사진은 JPEG 인코딩 전에 지정 RGB 변환을 한 번만 적용한다', () {
    final base = png(100, 120, [20, 40, 60, 255]);
    for (final id in ['original', 'warm', 'cold']) {
      final expected = filterTransformFor(id).applyReferenceRgb8(20, 40, 60);
      final exact = img.decodePng(
        compositePhoto(photoBytes: base, filterId: id, lossless: true),
      )!;
      final pixel = exact.getPixel(50, 60);
      expect([pixel.r, pixel.g, pixel.b], expected);
      final saved = img.decodeJpg(
        compositePhoto(photoBytes: base, filterId: id),
      )!;
      final savedPixel = saved.getPixel(50, 60);
      expect(savedPixel.r, closeTo(expected[0], 3));
      expect(savedPixel.g, closeTo(expected[1], 3));
      expect(savedPixel.b, closeTo(expected[2], 3));
    }
  });

  test('가로 사진 가운데를 5:6으로 잘라 좌우 가장자리를 제외한다', () {
    final source = img.Image(width: 240, height: 120);
    img.fill(source, color: img.ColorRgb8(255, 0, 0));
    img.fillRect(
      source,
      x1: 70,
      y1: 0,
      x2: 169,
      y2: 119,
      color: img.ColorRgb8(0, 200, 0),
    );
    final result = img.decodePng(
      compositePhoto(
        photoBytes: Uint8List.fromList(img.encodePng(source)),
        lossless: true,
      ),
    )!;
    expect((result.width, result.height), (100, 120));
    for (final x in [0, 50, 99]) {
      expect(result.getPixel(x, 60).g, 200);
      expect(result.getPixel(x, 60).r, 0);
    }
  });

  test('EXIF 방향을 먼저 보정하고 필터를 적용한다', () {
    final source = img.Image(width: 20, height: 10);
    img.fill(source, color: img.ColorRgb8(180, 50, 30));
    source.exif.imageIfd.orientation = 6;
    final bytes = Uint8List.fromList(img.encodeJpg(source));
    final result = img.decodePng(
      compositePhoto(
        photoBytes: bytes,
        filterId: 'warm',
        frameAspectRatio: .5,
        lossless: true,
      ),
    )!;
    expect((result.width, result.height), (10, 20));
    final expected = warmTransform.applyToImage(
      img.bakeOrientation(img.decodeJpg(bytes)!),
    );
    expect(result.getBytes(), expected.getBytes());
  });

  test('PNG 출력은 투명 이미지의 알파를 유지한다', () {
    for (final alpha in [0, 1, 128, 255]) {
      final output = img.decodePng(
        compositePhoto(
          photoBytes: png(10, 12, [170, 80, 30, alpha]),
          filterId: 'cold',
          lossless: true,
        ),
      )!;
      final pixel = output.getPixel(5, 6);
      expect(pixel.a, alpha);
      expect([
        pixel.r,
        pixel.g,
        pixel.b,
      ], coldTransform.applyReferenceRgb8(170, 80, 30));
    }
  });

  test('잘못된 이미지·필터 ID·범위 밖 강도를 거부한다', () {
    final base = png(10, 12, [0, 0, 0, 255]);
    for (final value in [-.1, 1.1, double.nan, double.infinity]) {
      expect(
        () => compositePhoto(photoBytes: base, intensity: value),
        throwsArgumentError,
      );
    }
    expect(
      () => compositePhoto(photoBytes: Uint8List(0)),
      throwsFormatException,
    );
    expect(
      () => compositePhoto(photoBytes: base, filterId: 'light'),
      throwsArgumentError,
    );
  });
}
