import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 감마 인코딩 sRGB의 straight RGB에서 수행하는 고정 Normal 색상층.
class FilterLayer {
  const FilterLayer(this.rgb, this.alpha);
  final List<double> rgb;
  final double alpha;
}

enum FilterFinish { none, multiply, linearBurn }

/// 앱 배경과 독립적인 필터 정의. 중간 단계에는 클리핑/정수화를 하지 않는다.
class FilterTransform {
  const FilterTransform(this.layers, this.finish);

  static const backgroundGray = 0.7492488026618958;
  final List<FilterLayer> layers;
  final FilterFinish finish;
  bool get isOriginal => finish == FilterFinish.none;

  double _reference(double input, int channel) {
    var value = input;
    for (final layer in layers) {
      value = value * (1 - layer.alpha) + layer.rgb[channel] * layer.alpha;
    }
    return switch (finish) {
      FilterFinish.none => value,
      FilterFinish.multiply => value * backgroundGray,
      FilterFinish.linearBurn => value + backgroundGray - 1,
    };
  }

  double get slope {
    var value = 1.0;
    for (final layer in layers) {
      value *= 1 - layer.alpha;
    }
    return finish == FilterFinish.multiply ? value * backgroundGray : value;
  }

  List<double> get offsets => List<double>.generate(3, (c) => _reference(0, c));

  /// Flutter 행렬의 오프셋 단위는 정규화 RGB가 아닌 0~255이다.
  /// RGB만 변경하고 알파 행은 항등 변환으로 유지한다.
  List<double> get colorMatrix {
    final offset = offsets;
    final scale = slope;
    return [
      scale,
      0,
      0,
      0,
      offset[0] * 255,
      0,
      scale,
      0,
      0,
      offset[1] * 255,
      0,
      0,
      scale,
      0,
      offset[2] * 255,
      0,
      0,
      0,
      1,
      0,
    ];
  }

  static int quantize(double value) =>
      (value.clamp(0.0, 1.0) * 255 + .5).floor();

  static void validateIntensity(double intensity) {
    if (!intensity.isFinite || intensity < 0 || intensity > 1) {
      throw ArgumentError.value(intensity, 'intensity', '0~1이어야 합니다.');
    }
  }

  // 최종 필터의 클리핑 뒤 원본과 혼합한다. cold의 음수를 섞으면 색이 달라진다.
  double _mixed(double input, int channel, double intensity) {
    if (intensity == 0 || isOriginal) return input;
    final filtered = _reference(input, channel).clamp(0.0, 1.0);
    return input * (1 - intensity) + filtered * intensity;
  }

  List<int> applyReferenceRgb8(
    int red,
    int green,
    int blue, {
    double intensity = 1,
  }) {
    validateIntensity(intensity);
    return [
      quantize(_mixed(red / 255, 0, intensity)),
      quantize(_mixed(green / 255, 1, intensity)),
      quantize(_mixed(blue / 255, 2, intensity)),
    ];
  }

  List<int> applyRgb8(int red, int green, int blue, {double intensity = 1}) {
    validateIntensity(intensity);
    final offset = offsets;
    final scale = slope;
    return [red, green, blue].asMap().entries.map((entry) {
      final input = entry.value / 255;
      final filtered = (input * scale + offset[entry.key]).clamp(0.0, 1.0);
      return quantize(input * (1 - intensity) + filtered * intensity);
    }).toList();
  }

  /// 원본을 변경하지 않고 straight RGB의 순차식으로 한 번만 적용한다.
  /// image 패키지의 straight RGB 픽셀을 사용하고 알파는 유지한다.
  img.Image applyToImage(img.Image source, {double intensity = 1}) {
    return applyToOwnedImage(source.clone(), intensity: intensity);
  }

  static final _cachedTables = Expando<Map<double, List<Uint8List>>>();

  List<Uint8List> _tables(double intensity) {
    final cache = _cachedTables[this] ??= <double, List<Uint8List>>{};
    final tables =
        cache.remove(intensity) ??
        List.generate(
          3,
          (channel) => Uint8List.fromList(
            List.generate(
              256,
              (value) => quantize(_mixed(value / 255, channel, intensity)),
            ),
          ),
        );
    cache[intensity] = tables;
    if (cache.length > 8) cache.remove(cache.keys.first);
    return tables;
  }

  /// 전용 isolate가 소유한 디코딩 버퍼에만 사용한다. 외부 입력에는 applyToImage를 사용한다.
  img.Image applyToOwnedImage(img.Image source, {double intensity = 1}) {
    validateIntensity(intensity);
    if (isOriginal || intensity == 0) return source;
    final input = source.hasPalette ? source.convert(numChannels: 4) : source;
    final output = input.format == img.Format.uint8 && input.numChannels >= 3
        ? input
        : input.convert(
            format: img.Format.uint8,
            numChannels: input.hasAlpha ? 4 : 3,
          );
    final tables = _tables(intensity);
    if (identical(output, input) && input.format == img.Format.uint8) {
      final bytes = output.toUint8List();
      final stride = output.numChannels;
      for (var offset = 0; offset < bytes.length; offset += stride) {
        bytes[offset] = tables[0][bytes[offset]];
        bytes[offset + 1] = tables[1][bytes[offset + 1]];
        bytes[offset + 2] = tables[2][bytes[offset + 2]];
      }
      return output;
    }
    for (final pixel in input) {
      final target = output.getPixel(pixel.x, pixel.y);
      if (input.format == img.Format.uint8) {
        target.r = tables[0][pixel.r.toInt()];
        target.g = tables[1][pixel.g.toInt()];
        target.b = tables[2][pixel.b.toInt()];
      } else {
        target.r = quantize(_mixed(pixel.rNormalized.toDouble(), 0, intensity));
        target.g = quantize(_mixed(pixel.gNormalized.toDouble(), 1, intensity));
        target.b = quantize(_mixed(pixel.bNormalized.toDouble(), 2, intensity));
      }
    }
    return output;
  }
}

const originalTransform = FilterTransform([], FilterFinish.none);
const warmTransform = FilterTransform([
  FilterLayer([
    0.529807448387146,
    0.17405542731285095,
    0.10290497541427612,
  ], 0.18000000715255737),
  FilterLayer([
    0.6105769276618958,
    0.21722447872161865,
    0.21722447872161865,
  ], 0.019999999552965164),
], FilterFinish.multiply);
const coldTransform = FilterTransform([
  FilterLayer([
    0.3588595688343048,
    0.33140718936920166,
    0.5144230723381042,
  ], 0.20000000298023224),
  FilterLayer([
    0.8176820278167725,
    0.6125569343566895,
    0.9451922178268433,
  ], 0.10000000149011612),
  FilterLayer([
    0.6400055289268494,
    0.8045783638954163,
    0.8644230365753174,
  ], 0.10999999940395355),
], FilterFinish.linearBurn);

FilterTransform filterTransformFor(String id) => switch (id) {
  'original' => originalTransform,
  'warm' => warmTransform,
  'cold' => coldTransform,
  _ => throw ArgumentError.value(id, 'filterId', '알 수 없는 필터입니다.'),
};
