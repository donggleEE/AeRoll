// 최적화 전 이미지 복사·픽셀 순회·인코딩 경로를 보존한 회귀/측정 기준이다.
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'package:aeroll/models/filter_transform.dart';

/// 기존 방향·크롭·줌 순서를 유지한 뒤 공통 고정 RGB 변환을 한 번 적용한다.
/// 플랫폼 API를 사용하지 않아 isolate와 단위 테스트에서 실행할 수 있다.
Uint8List compositePhoto({
  required Uint8List photoBytes,
  String filterId = 'original',
  bool lossless = false,
  double intensity = 1,
  double frameAspectRatio = 5 / 6,
  bool mirrorHorizontally = false,
  double digitalScale = 1,
  Map<String, int>? timings,
}) {
  if (!intensity.isFinite || intensity < 0 || intensity > 1) {
    throw ArgumentError.value(intensity, 'intensity', '0~1이어야 합니다.');
  }
  if (!digitalScale.isFinite || digitalScale < 1) {
    throw ArgumentError.value(digitalScale, 'digitalScale', '1 이상이어야 합니다.');
  }
  final clock = Stopwatch()..start();
  void mark(String name) {
    timings?[name] = clock.elapsedMicroseconds;
    clock.reset();
  }

  final decoded = img.decodeImage(photoBytes);
  mark('decode');
  if (decoded == null) {
    throw const FormatException('촬영한 사진을 읽을 수 없습니다.');
  }
  if (!frameAspectRatio.isFinite || frameAspectRatio <= 0) {
    throw ArgumentError.value(frameAspectRatio, 'frameAspectRatio');
  }
  var oriented = img.bakeOrientation(decoded);
  if (mirrorHorizontally) oriented = img.flipHorizontal(oriented);
  mark('orientation');
  var photo = _cropToFrame(oriented, frameAspectRatio);
  if (digitalScale > 1) {
    final width = (photo.width / digitalScale).round().clamp(1, photo.width);
    final height = (photo.height / digitalScale).round().clamp(1, photo.height);
    final cropped = img.copyCrop(
      photo,
      x: ((photo.width - width) / 2).floor(),
      y: ((photo.height - height) / 2).floor(),
      width: width,
      height: height,
    );
    photo = img.copyResize(
      cropped,
      width: photo.width,
      height: photo.height,
      interpolation: img.Interpolation.linear,
    );
  }
  mark('cropResize');
  photo = legacyFilter(photo, filterId, intensity);
  mark('filter');
  final encoded = Uint8List.fromList(
    lossless ? img.encodePng(photo) : img.encodeJpg(photo, quality: 95),
  );
  mark('encode');
  return encoded;
}

img.Image _cropToFrame(img.Image source, double aspectRatio) {
  if (aspectRatio != 5 / 6) {
    final width = source.width / source.height > aspectRatio
        ? (source.height * aspectRatio).round().clamp(1, source.width)
        : source.width;
    final height = source.width / source.height > aspectRatio
        ? source.height
        : (source.width / aspectRatio).round().clamp(1, source.height);
    return img.copyCrop(
      source,
      x: ((source.width - width) / 2).floor(),
      y: ((source.height - height) / 2).floor(),
      width: width,
      height: height,
    );
  }
  // 5와 6의 정수 배수로 잘라 미리보기 비율을 정확하게 유지한다.
  final unit = (source.width / 5).floor() < (source.height / 6).floor()
      ? (source.width / 5).floor()
      : (source.height / 6).floor();
  if (unit < 1) {
    throw const FormatException('사진 크기가 너무 작습니다.');
  }
  final width = unit * 5;
  final height = unit * 6;
  return img.copyCrop(
    source,
    x: ((source.width - width) / 2).floor(),
    y: ((source.height - height) / 2).floor(),
    width: width,
    height: height,
  );
}

/// compute 콜백에서는 에셋/플러그인 대신 전달받은 바이트만 사용한다.
Uint8List processPhoto(Map<String, Object?> request) => compositePhoto(
  photoBytes: request['photoBytes']! as Uint8List,
  filterId: request['filterId'] as String? ?? 'original',
  lossless: request['lossless'] as bool? ?? false,
  intensity: request['intensity']! as double,
  frameAspectRatio: request['frameAspectRatio'] as double? ?? 5 / 6,
  mirrorHorizontally: request['mirrorHorizontally'] as bool? ?? false,
  digitalScale: request['digitalScale'] as double? ?? 1,
);

img.Image legacyFilter(img.Image source, String id, double intensity) {
  final transform = filterTransformFor(id);
  if (transform.isOriginal || intensity == 0) return source.clone();
  final input = source.hasPalette ? source.convert(numChannels: 4) : source;
  final output = input.convert(
    format: img.Format.uint8,
    numChannels: input.hasAlpha ? 4 : 3,
  );
  final table = List.generate(
    256,
    (n) => transform.applyReferenceRgb8(n, n, n, intensity: intensity),
  );
  for (final pixel in input) {
    final target = output.getPixel(pixel.x, pixel.y);
    target.r = table[pixel.r.toInt()][0];
    target.g = table[pixel.g.toInt()][1];
    target.b = table[pixel.b.toInt()][2];
  }
  return output;
}
