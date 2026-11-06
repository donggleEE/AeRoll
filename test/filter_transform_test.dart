import 'package:aeroll/models/filter_transform.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

// 사용자 제공 수식을 독립적으로 계산해 실제 최적화 구현과 비교한다.
List<int> specification(List<int> input, bool warm, {double intensity = 1}) {
  const gray = 0.7492488026618958;
  final layers = warm
      ? [
          (
            [0.529807448387146, 0.17405542731285095, 0.10290497541427612],
            0.18000000715255737,
          ),
          (
            [0.6105769276618958, 0.21722447872161865, 0.21722447872161865],
            0.019999999552965164,
          ),
        ]
      : [
          (
            [0.3588595688343048, 0.33140718936920166, 0.5144230723381042],
            0.20000000298023224,
          ),
          (
            [0.8176820278167725, 0.6125569343566895, 0.9451922178268433],
            0.10000000149011612,
          ),
          (
            [0.6400055289268494, 0.8045783638954163, 0.8644230365753174],
            0.10999999940395355,
          ),
        ];
  return List.generate(3, (c) {
    var value = input[c] / 255;
    for (final layer in layers) {
      value = value * (1 - layer.$2) + layer.$1[c] * layer.$2;
    }
    value = warm ? value * gray : value + gray - 1;
    value =
        input[c] / 255 * (1 - intensity) + value.clamp(0.0, 1.0) * intensity;
    return (value.clamp(0.0, 1.0) * 255 + .5).floor();
  });
}

void main() {
  test('0·50·100%와 모든 채널값에서 최종 클리핑 뒤 원본을 혼합한다', () {
    for (final warm in [true, false]) {
      final transform = warm ? warmTransform : coldTransform;
      for (final intensity in [0.0, .01, .5, .9, .99, 1.0]) {
        for (var n = 0; n < 256; n++) {
          final input = [n, (n * 3) % 256, (n * 7) % 256];
          final expected = specification(input, warm, intensity: intensity);
          expect(
            transform.applyReferenceRgb8(
              input[0],
              input[1],
              input[2],
              intensity: intensity,
            ),
            expected,
          );
          expect(
            transform.applyRgb8(
              input[0],
              input[1],
              input[2],
              intensity: intensity,
            ),
            expected,
          );
        }
      }
    }
    // 원본20을 음수인 cold 최종값과 바로 섞으면 이 값보다 어두워진다.
    expect(coldTransform.applyRgb8(20, 20, 20, intensity: .5).take(2), [
      10,
      10,
    ]);
  });

  test('부분 강도 픽셀 처리는 알파·원본을 보존하고 잘못된 강도를 거부한다', () {
    final input = img.Image(width: 1, height: 1, numChannels: 4)
      ..setPixelRgba(0, 0, 20, 30, 40, 128);
    final before = input.getBytes().toList();
    for (final transform in [originalTransform, warmTransform, coldTransform]) {
      for (final intensity in [0.0, .5, 1.0]) {
        final pixel = transform
            .applyToImage(input, intensity: intensity)
            .getPixel(0, 0);
        expect([
          pixel.r,
          pixel.g,
          pixel.b,
        ], transform.applyReferenceRgb8(20, 30, 40, intensity: intensity));
        expect(pixel.a, 128);
      }
      for (final value in [-.1, 1.1, double.nan, double.infinity]) {
        expect(
          () => transform.applyToImage(input, intensity: value),
          throwsArgumentError,
        );
      }
    }
    expect(input.getBytes(), before);
  });
  test('팔레트 투명 이미지를 straight RGBA로 변환해 알파를 보존한다', () {
    final input = img.Image(
      width: 1,
      height: 1,
      numChannels: 4,
      withPalette: true,
    );
    input.palette!.setRgba(0, 170, 80, 30, 128);
    input.getPixel(0, 0).index = 0;
    final pixel = coldTransform.applyToImage(input).getPixel(0, 0);
    expect(pixel.a, 128);
    expect([
      pixel.r,
      pixel.g,
      pixel.b,
    ], coldTransform.applyReferenceRgb8(170, 80, 30));
  });
  const samples = [
    [0, 0, 0],
    [255, 255, 255],
    [128, 128, 128],
    [255, 0, 0],
    [0, 255, 0],
    [0, 0, 255],
  ];
  test('필수 RGB 입력에서 순차 Normal 합성과 최종 합성·반올림이 명세와 같다', () {
    for (final rgb in samples) {
      for (final warm in [true, false]) {
        final transform = warm ? warmTransform : coldTransform;
        final expected = specification(rgb, warm);
        expect(transform.applyReferenceRgb8(rgb[0], rgb[1], rgb[2]), expected);
        expect(transform.applyRgb8(rgb[0], rgb[1], rgb[2]), expected);
      }
      expect(originalTransform.applyRgb8(rgb[0], rgb[1], rgb[2]), rgb);
    }
    expect(coldTransform.applyRgb8(0, 0, 0).take(2), [0, 0]);
  });
  test('전 채널의 모든 8bit 값에서 선형식과 순차식이 일치한다', () {
    for (final transform in [originalTransform, warmTransform, coldTransform]) {
      for (var n = 0; n < 256; n++) {
        expect(
          transform.applyRgb8(n, n, n),
          transform.applyReferenceRgb8(n, n, n),
        );
      }
    }
  });
  test('전환·재선택은 원본을 변경하지 않고 알파와 straight RGB를 유지한다', () {
    final input = img.Image(width: 6, height: 1, numChannels: 4);
    for (var x = 0; x < 6; x++) {
      input.setPixelRgba(
        x,
        0,
        samples[x][0],
        samples[x][1],
        samples[x][2],
        x * 51,
      );
    }
    final before = input.getBytes().toList();
    final first = warmTransform.applyToImage(input);
    coldTransform.applyToImage(input);
    final again = warmTransform.applyToImage(input);
    expect(first.getBytes(), again.getBytes());
    expect(input.getBytes(), before);
    expect(originalTransform.applyToImage(input).getBytes(), before);
    for (var x = 0; x < 6; x++) {
      final pixel = first.getPixel(x, 0);
      expect(pixel.a, x * 51);
      expect([pixel.r, pixel.g, pixel.b], specification(samples[x], true));
    }
  });
}
