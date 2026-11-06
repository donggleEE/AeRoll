import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:aeroll/models/filter_transform.dart';
import 'package:image/image.dart' as img;

/// 실제 앱 변환으로 비교하며 크롭·리사이즈·계수 보정은 하지 않는다.
Future<void> main(List<String> args) async {
  if (args.length != 4) {
    stdout.writeln(
      '사용법: dart run tool/compare_filter_references.dart '
      '<base.jpg> <warm_reference.jpg> <cold_reference.jpg> <출력폴더>',
    );
    exitCode = 64;
    return;
  }
  final files = args.take(3).map(File.new).toList();
  final images = <img.Image>[];
  for (final file in files) {
    final image = img.decodeImage(await file.readAsBytes());
    if (image == null) throw FormatException('이미지를 읽을 수 없습니다: ${file.path}');
    images.add(img.bakeOrientation(image));
  }
  final base = images.first;
  for (final reference in images.skip(1)) {
    if (reference.width != base.width || reference.height != base.height) {
      throw ArgumentError('방향 보정 후 크기가 다릅니다. 자동 크롭·리사이즈는 하지 않습니다.');
    }
  }
  final output = Directory(args[3]);
  final targets = [
    'warm_output.png',
    'cold_output.png',
    'comparison.json',
  ].map((name) => File('${output.path}/$name')).toList();
  for (final file in targets) {
    if (await file.exists()) {
      throw ArgumentError('새 출력 폴더를 지정해 주세요: ${file.path}');
    }
  }
  final report = <String, Object?>{
    'inputs': files.map((file) => file.path).toList(),
    'width': base.width,
    'height': base.height,
    'colorSpaceAssumption': 'sRGB',
    'processing': 'EXIF 방향 보정, 크롭·리사이즈·자동 보정 없음, 원본에서 각각 한 번 변환',
    'signedErrorConvention': '계산 출력 - 기준 JPG, 채널 범위 0~255',
    'iccLimitation': 'ICC 프로필에서 sRGB로의 변환은 수행하지 않음',
  };
  await output.create(recursive: true);
  final transforms = [warmTransform, coldTransform];
  for (var i = 0; i < transforms.length; i++) {
    final result = transforms[i].applyToImage(base);
    await targets[i].writeAsBytes(img.encodePng(result));
    report[i == 0 ? 'warm' : 'cold'] = measure(result, images[i + 1]);
  }
  final json = const JsonEncoder.withIndent('  ').convert(report);
  await targets.last.writeAsString('$json\n');
  stdout.writeln(json);
}

Map<String, Object> measure(img.Image actual, img.Image reference) {
  final absolute = [0.0, 0.0, 0.0];
  final signed = [0.0, 0.0, 0.0];
  var squares = 0.0;
  for (var y = 0; y < actual.height; y++) {
    for (var x = 0; x < actual.width; x++) {
      final a = actual.getPixel(x, y), b = reference.getPixel(x, y);
      final differences = [
        (a.rNormalized - b.rNormalized) * 255,
        (a.gNormalized - b.gNormalized) * 255,
        (a.bNormalized - b.bNormalized) * 255,
      ];
      for (var c = 0; c < 3; c++) {
        final difference = differences[c].toDouble();
        absolute[c] += difference.abs();
        signed[c] += difference;
        squares += difference * difference;
      }
    }
  }
  final count = actual.width * actual.height;
  return {
    'channelOrder': ['R', 'G', 'B'],
    'mae': absolute.map((value) => value / count).toList(),
    'meanSignedError': signed.map((value) => value / count).toList(),
    'rmse': math.sqrt(squares / (count * 3)),
  };
}
