import 'dart:io';
import 'dart:typed_data';

import 'package:aeroll/services/photo_compositor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

Uint8List png(int width, int height, List<int> rgba) {
  final image = img.Image(width: width, height: height, numChannels: 4);
  img.fill(image, color: img.ColorRgba8(rgba[0], rgba[1], rgba[2], rgba[3]));
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  test('PNG의 원래 알파에 강도를 곱해 source-over 합성한다', () {
    final base = png(100, 120, [20, 40, 60, 255]);
    final overlay = png(100, 120, [220, 140, 60, 128]);
    for (final intensity in [0.0, 0.5, 1.0]) {
      final result = img.decodeJpg(
        compositePhoto(
          photoBytes: base,
          overlayBytes: overlay,
          intensity: intensity,
        ),
      )!;
      final pixel = result.getPixel(50, 60);
      final alpha = (128 * intensity).round() / 255;
      expect(pixel.r, closeTo(20 + 200 * alpha, 3));
      expect(pixel.g, closeTo(40 + 100 * alpha, 3));
      expect(pixel.b, closeTo(60, 3));
    }
  });

  test('가로 사진의 가운데를 5:6으로 잘라 좌우 가장자리를 제외한다', () {
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
    final result = img.decodeJpg(
      compositePhoto(photoBytes: Uint8List.fromList(img.encodePng(source))),
    )!;
    expect((result.width, result.height), (100, 120));
    for (final x in [0, 50, 99]) {
      expect(result.getPixel(x, 60).g, closeTo(200, 3));
      expect(result.getPixel(x, 60).r, lessThan(5));
    }
  });

  test('실제 제공 필터가 최종 파일의 색상을 바꾼다', () {
    final base = png(100, 120, [100, 100, 100, 255]);
    final raw = img.decodeJpg(compositePhoto(photoBytes: base))!;
    final filtered = img.decodeJpg(
      compositePhoto(
        photoBytes: base,
        overlayBytes: File('assets/images/filter/light.png').readAsBytesSync(),
      ),
    )!;
    expect((filtered.width, filtered.height), (100, 120));
    final changes = <int>[];
    for (var y = 10; y < 120; y += 20) {
      for (var x = 10; x < 100; x += 20) {
        final a = raw.getPixel(x, y);
        final b = filtered.getPixel(x, y);
        changes.add(
          (a.r - b.r).abs().toInt() +
              (a.g - b.g).abs().toInt() +
              (a.b - b.b).abs().toInt(),
        );
      }
    }
    expect(changes.any((value) => value > 10), isTrue);
  });

  test('잘못된 이미지와 범위 밖 강도를 거부한다', () {
    final base = png(10, 12, [0, 0, 0, 255]);
    for (final value in [-0.1, 1.1, double.nan, double.infinity]) {
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
      () => compositePhoto(photoBytes: base, overlayBytes: Uint8List(0)),
      throwsFormatException,
    );
  });
}
