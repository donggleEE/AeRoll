import 'dart:io';

import 'package:aeroll/models/filter_transform.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../tool/compare_filter_references.dart' show measure;

void main() {
  test('오차 집계는 RGB별 MAE·출력에서 기준을 뺀 평균·전체 RMSE를 계산한다', () {
    final actual = img.Image(width: 1, height: 1)
      ..setPixelRgb(0, 0, 10, 20, 30);
    final reference = img.Image(width: 1, height: 1)
      ..setPixelRgb(0, 0, 7, 24, 30);
    final result = measure(actual, reference);
    final mae = result['mae']! as List<double>;
    final signed = result['meanSignedError']! as List<double>;
    for (var c = 0; c < 3; c++) {
      expect(mae[c], closeTo([3, 4, 0][c], 1e-10));
      expect(signed[c], closeTo([3, -4, 0][c], 1e-10));
    }
    expect(result['rmse'], closeTo(2.886751345948129, 1e-10));
  });

  test('제공된 JPG와 100% 필터 결과의 크기를 유지하고 기준 오차 범위를 검사한다', () {
    img.Image read(String name) => img.bakeOrientation(
      img.decodeJpg(
        File('test/fixtures/filter_reference/$name.jpg').readAsBytesSync(),
      )!,
    );
    final base = read('base');
    final untouched = base.getBytes().toList();
    for (final entry in [
      ('warm_reference', warmTransform),
      ('cold_reference', coldTransform),
    ]) {
      final reference = read(entry.$1);
      final result = entry.$2.applyToImage(base);
      expect((result.width, result.height), (base.width, base.height));
      expect((reference.width, reference.height), (base.width, base.height));
      // 손실 JPG·디코더 오차를 허용하는 회귀 경계이며 계수 보정 목표가 아니다.
      expect(measure(result, reference)['rmse']! as double, lessThan(3.5));
    }
    expect(base.getBytes(), untouched);
  });
}
