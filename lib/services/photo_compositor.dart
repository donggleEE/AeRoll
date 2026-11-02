import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 미리보기와 동일한 중앙 크롭 및 source-over 합성을 수행한다.
/// 플랫폼 API를 사용하지 않아 isolate와 단위 테스트에서 실행할 수 있다.
Uint8List compositePhoto({
  required Uint8List photoBytes,
  Uint8List? overlayBytes,
  img.Image? decodedOverlay,
  double intensity = 1,
  double frameAspectRatio = 5 / 6,
  bool mirrorHorizontally = false,
}) {
  if (!intensity.isFinite || intensity < 0 || intensity > 1) {
    throw ArgumentError.value(intensity, 'intensity', '0~1이어야 합니다.');
  }
  final decoded = img.decodeImage(photoBytes);
  if (decoded == null) {
    throw const FormatException('촬영한 사진을 읽을 수 없습니다.');
  }
  if (!frameAspectRatio.isFinite || frameAspectRatio <= 0) {
    throw ArgumentError.value(frameAspectRatio, 'frameAspectRatio');
  }
  var oriented = img.bakeOrientation(decoded);
  if (mirrorHorizontally) oriented = img.flipHorizontal(oriented);
  final photo = _cropToFrame(oriented, frameAspectRatio);
  if ((overlayBytes != null || decodedOverlay != null) && intensity > 0) {
    final overlayImage = decodedOverlay ?? img.decodeImage(overlayBytes!);
    if (overlayImage == null) {
      throw const FormatException('필터 이미지를 읽을 수 없습니다.');
    }
    final overlay = img
        .copyResize(
          _cropToFrame(overlayImage, frameAspectRatio),
          width: photo.width,
          height: photo.height,
          interpolation: img.Interpolation.linear,
        )
        .convert(numChannels: 4);
    if (intensity < 1) {
      for (final pixel in overlay) {
        pixel.a = (pixel.a * intensity).round();
      }
    }
    img.compositeImage(photo, overlay);
  }
  return Uint8List.fromList(img.encodeJpg(photo, quality: 95));
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
  overlayBytes: request['overlayBytes'] as Uint8List?,
  intensity: request['intensity']! as double,
  frameAspectRatio: request['frameAspectRatio'] as double? ?? 5 / 6,
  mirrorHorizontally: request['mirrorHorizontally'] as bool? ?? false,
);
