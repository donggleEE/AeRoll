import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:image/image.dart' as img;

import '../test/support/legacy_photo_pipeline.dart' as legacy;

import 'package:aeroll/services/photo_compositor.dart' as current;

Future<void> main(List<String> args) async {
  final before = args.contains('before');
  final zoom = args.contains('zoom');
  if (!args.contains('prepare') &&
      !File('build/photo_latency_input.jpg').existsSync()) {
    throw ArgumentError('먼저 prepare로 입력을 생성해 주세요.');
  }
  final fixture = File('build/photo_latency_input.jpg');
  fixture.parent.createSync(recursive: true);
  if (!fixture.existsSync()) {
    final image = img.Image(width: 4000, height: 3000);
    for (final pixel in image) {
      pixel.setRgb(pixel.x % 256, pixel.y % 256, (pixel.x + pixel.y) % 256);
    }
    fixture.writeAsBytesSync(img.encodeJpg(image, quality: 95));
  }
  if (args.contains('prepare')) return;
  final reports = <Object>[];
  for (final filter in zoom ? ['cold'] : ['original', 'cold']) {
    var beats = 0;
    final timer = Timer.periodic(
      const Duration(milliseconds: 10),
      (_) => beats++,
    );
    final result = await Isolate.run(() {
      final bytes = fixture.readAsBytesSync();
      final samples = <Map<String, int>>[];
      var size = 0;
      for (var n = 0; n < 4; n++) {
        final stages = <String, int>{};
        final clock = Stopwatch()..start();
        final output = before
            ? legacy.compositePhoto(
                photoBytes: bytes,
                filterId: filter,
                intensity: .5,
                frameAspectRatio: 4 / 3,
                digitalScale: zoom ? 3 : 1,
                timings: stages,
              )
            : current.compositePhoto(
                photoBytes: bytes,
                filterId: filter,
                intensity: .5,
                frameAspectRatio: 4 / 3,
                digitalScale: zoom ? 3 : 1,
                timings: stages,
                onThumbnail: (_) {},
              );
        size = output.length;
        stages['total'] = clock.elapsedMicroseconds;
        if (n > 0) samples.add(stages);
      }
      return {
        'filter': filter,
        'digitalScale': zoom ? 3 : 1,
        'samplesUs': samples,
        'outputBytes': size,
      };
    });
    timer.cancel();
    reports.add({
      ...result,
      'mainHeartbeats': beats,
      'maxRssBytes': ProcessInfo.maxRss,
    });
  }
  final json = const JsonEncoder.withIndent('  ').convert(reports);
  final filename = before
      ? 'build/photo_latency_before.json'
      : 'build/photo_latency_after.json';
  File(filename.replaceFirst('.json', zoom ? '_zoom.json' : '.json'))
      .writeAsStringSync(json);
  stdout.writeln(json);
}
