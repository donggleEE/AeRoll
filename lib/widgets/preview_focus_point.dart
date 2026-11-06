import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

/// 표시된 미리보기의 자르기·디지털 확대·앱의 추가 반전을 역변환한다.
/// 반환값은 camera 플러그인의 회전된 미리보기 기준 0~1 좌표다.
/// 센서 방향 변환은 플랫폼의 초점 API가 수행하므로 중복 회전하지 않는다.
/// mirrored는 앱의 추가 flip이다. Android CameraX는 전면 미러를 자체 보정하지만
/// iOS는 방향만 보정하므로 해당 플랫폼에서는 기본 전면 미러도 해제한다.
Offset? previewFocusPoint({
  required Offset position,
  required Size viewport,
  required Size previewSize,
  required DeviceOrientation orientation,
  DeviceOrientation? meteringOrientation,
  required BoxFit fit,
  required double digitalZoom,
  required bool mirrored,
  bool isFrontCamera = false,
  bool platformHandlesFrontMirror = true,
}) {
  if (viewport.isEmpty ||
      previewSize.isEmpty ||
      !digitalZoom.isFinite ||
      digitalZoom < 1) {
    return null;
  }
  final portrait =
      orientation == DeviceOrientation.portraitUp ||
      orientation == DeviceOrientation.portraitDown;
  final source = portrait
      ? Size(previewSize.height, previewSize.width)
      : previewSize;
  final fitted = applyBoxFit(fit, source, viewport);
  final destination = Alignment.center.inscribe(
    fitted.destination,
    Offset.zero & viewport,
  );
  final sourceRect = Alignment.center.inscribe(
    fitted.source,
    Offset.zero & source,
  );
  final unzoomed = Offset(
    viewport.width / 2 + (position.dx - viewport.width / 2) / digitalZoom,
    viewport.height / 2 + (position.dy - viewport.height / 2) / digitalZoom,
  );
  if (!destination.contains(unzoomed)) return null;
  var x =
      (sourceRect.left +
          (unzoomed.dx - destination.left) /
              destination.width *
              sourceRect.width) /
      source.width;
  final y =
      (sourceRect.top +
          (unzoomed.dy - destination.top) /
              destination.height *
              sourceRect.height) /
      source.height;
  if (mirrored) x = 1 - x;
  // iOS만 기본 전면 미러를 해제한다. CameraX는 플랫폼의 factory가 처리한다.
  if (isFrontCamera && !platformHandlesFrontMirror) x = 1 - x;
  final sensor = _toSensor(Offset(x, y), orientation);
  final point = _fromSensor(sensor, meteringOrientation ?? orientation);
  return Offset(point.dx.clamp(0, 1), point.dy.clamp(0, 1));
}

Offset _toSensor(Offset point, DeviceOrientation orientation) =>
    switch (orientation) {
      DeviceOrientation.portraitUp => Offset(point.dy, 1 - point.dx),
      DeviceOrientation.portraitDown => Offset(1 - point.dy, point.dx),
      DeviceOrientation.landscapeRight => Offset(1 - point.dx, 1 - point.dy),
      DeviceOrientation.landscapeLeft => point,
    };

Offset _fromSensor(Offset point, DeviceOrientation orientation) =>
    switch (orientation) {
      DeviceOrientation.portraitUp => Offset(1 - point.dy, point.dx),
      DeviceOrientation.portraitDown => Offset(point.dy, 1 - point.dx),
      DeviceOrientation.landscapeRight => Offset(1 - point.dx, 1 - point.dy),
      DeviceOrientation.landscapeLeft => point,
    };
