import 'package:aeroll/widgets/preview_focus_point.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Offset? map(
    Offset position, {
    double zoom = 1,
    bool flip = false,
    BoxFit fit = BoxFit.cover,
    DeviceOrientation orientation = DeviceOrientation.portraitUp,
  }) => previewFocusPoint(
    position: position,
    viewport: const Size(100, 100),
    previewSize: const Size(200, 100),
    orientation: orientation,
    fit: fit,
    digitalZoom: zoom,
    mirrored: flip,
  );
  test('세로·가로 회전에 맞는 중앙 크롭과 확대를 역변환한다', () {
    expect(map(const Offset(0, 50)), const Offset(0, .5));
    expect(map(const Offset(0, 50), zoom: 2), const Offset(.25, .5));
    expect(
      map(const Offset(0, 50), orientation: DeviceOrientation.landscapeLeft),
      const Offset(.25, .5),
    );
    expect(map(const Offset(50, 0)), const Offset(.5, .25));
    expect(
      map(const Offset(50, 0), orientation: DeviceOrientation.portraitDown),
      const Offset(.5, .25),
    );
  });
  test('플랫폼 전면 미러를 중복 보정하지 않고 앱의 추가 flip만 역변환한다', () {
    expect(map(const Offset(25, 50)), const Offset(.25, .5));
    expect(map(const Offset(25, 50), flip: true), const Offset(.75, .5));
    expect(
      map(const Offset(25, 50), flip: true, zoom: 2),
      const Offset(.625, .5),
    );
  });
  test('contain 검정 여백 탭은 초점 요청을 만들지 않는다', () {
    expect(map(const Offset(0, 50), fit: BoxFit.contain), isNull);
    expect(
      map(const Offset(50, 50), fit: BoxFit.contain),
      const Offset(.5, .5),
    );
  });
  test('iOS는 기본 전면 미러를 해제하고 Android는 플랫폼 보정과 중복하지 않는다', () {
    Offset? front(bool handlesMirror, bool appFlip) => previewFocusPoint(
      position: const Offset(25, 50),
      viewport: const Size(100, 100),
      previewSize: const Size(200, 100),
      orientation: DeviceOrientation.portraitUp,
      fit: BoxFit.cover,
      digitalZoom: 1,
      mirrored: appFlip,
      isFrontCamera: true,
      platformHandlesFrontMirror: handlesMirror,
    );
    expect(front(true, false), const Offset(.25, .5));
    expect(front(true, true), const Offset(.75, .5));
    expect(front(false, false), const Offset(.75, .5));
    expect(front(false, true), const Offset(.25, .5));
  });
  test('고정 미리보기 방향과 플랫폼 metering 방향이 다를 때 센서 좌표로 연결한다', () {
    Offset? rotate(DeviceOrientation metering) => previewFocusPoint(
      position: const Offset(20, 70),
      viewport: const Size(100, 100),
      previewSize: const Size(100, 100),
      orientation: DeviceOrientation.portraitUp,
      meteringOrientation: metering,
      fit: BoxFit.cover,
      digitalZoom: 1,
      mirrored: false,
    );
    final left = rotate(DeviceOrientation.landscapeLeft)!;
    expect(left.dx, closeTo(.7, 1e-10));
    expect(left.dy, closeTo(.8, 1e-10));
    final right = rotate(DeviceOrientation.landscapeRight)!;
    expect(right.dx, closeTo(.3, 1e-10));
    expect(right.dy, closeTo(.2, 1e-10));
    final down = rotate(DeviceOrientation.portraitDown)!;
    expect(down.dx, closeTo(.8, 1e-10));
    expect(down.dy, closeTo(.3, 1e-10));
  });
  test('전면 가로 회전은 Android의 플랫폼 미러 보정과 iOS의 앱 보정을 구분한다', () {
    Offset? front(bool nativeMirror, bool appFlip) => previewFocusPoint(
      position: const Offset(20, 70),
      viewport: const Size(100, 100),
      previewSize: const Size(100, 100),
      orientation: DeviceOrientation.portraitUp,
      meteringOrientation: DeviceOrientation.landscapeLeft,
      fit: BoxFit.cover,
      digitalZoom: 1,
      mirrored: appFlip,
      isFrontCamera: true,
      platformHandlesFrontMirror: nativeMirror,
    );
    expect(front(true, false)!.dx, closeTo(.7, 1e-10));
    expect(front(true, false)!.dy, closeTo(.8, 1e-10));
    expect(front(true, true)!.dy, closeTo(.2, 1e-10));
    expect(front(false, false)!.dy, closeTo(.2, 1e-10));
    expect(front(false, true)!.dy, closeTo(.8, 1e-10));
  });
}
