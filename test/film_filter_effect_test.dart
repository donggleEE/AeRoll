import 'dart:ui' as ui;

import 'package:aeroll/models/film_filter.dart';
import 'package:aeroll/widgets/film_filter_effect.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const _samples = <List<int>>[
  [0, 0, 0],
  [255, 255, 255],
  [128, 128, 128],
  [255, 0, 0],
  [0, 255, 0],
  [0, 0, 255],
  [20, 20, 20],
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('필터 혼합은 사진 밖 배경색과 독립적이다', (tester) async {
    final key = GlobalKey();
    for (final strength in [.01, .5, .99]) {
      for (final background in [
        const Color(0xffdd1177),
        const Color(0xff11cc66),
      ]) {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: RepaintBoundary(
                key: key,
                child: ColoredBox(
                  color: background,
                  child: SizedBox(
                    width: 10,
                    height: 10,
                    child: FilmFilterEffect(
                      filter: filmFilters[2],
                      intensity: strength,
                      child: const ColoredBox(
                        color: Color.fromARGB(128, 20, 30, 40),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = (await tester.runAsync(
          () => boundary.toImage(pixelRatio: 1),
        ))!;
        final bytes = (await tester.runAsync(
          () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
        ))!;
        final filtered = filmFilters[2].transform.applyReferenceRgb8(
          20,
          30,
          40,
          intensity: strength,
        );
        final bg = [background.r * 255, background.g * 255, background.b * 255];
        for (var c = 0; c < 3; c++) {
          expect(
            bytes.getUint8((5 * 10 + 5) * 4 + c),
            // 분기별 premultiplied 반올림과 배경 합성 반올림을 각각 허용한다.
            closeTo(filtered[c] * 128 / 255 + bg[c] * 127 / 255, 2),
          );
        }
        expect(bytes.getUint8((5 * 10 + 5) * 4 + 3), 255);
        image.dispose();
      }
    }
  });
  test('런타임 셰이더 에셋을 로드하고 혼합 uniform을 설정한다', () async {
    final program = await ui.FragmentProgram.fromAsset(
      'assets/shaders/film_filter.frag',
    );
    final shader = program.fragmentShader();
    for (var index = 0; index < 7; index++) {
      shader.setFloat(index, index == 6 ? .5 : 1);
    }
    shader.dispose();
  });
  testWidgets('불투명 sRGB 렌더링은 CPU 기준식과 일치하고 전환이 누적되지 않는다', (tester) async {
    final boundaryKey = GlobalKey();
    for (final (filter, intensity, opaque) in [
      for (final filter in [
        filmFilters[1],
        filmFilters[2],
        filmFilters[0],
        filmFilters[1],
      ])
        for (final intensity in [0.0, .01, .5, .9, .99, 1.0])
          for (final opaque in [false, true]) (filter, intensity, opaque),
    ]) {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: RepaintBoundary(
              key: boundaryKey,
              child: SizedBox(
                width: 70,
                height: 10,
                child: FilmFilterEffect(
                  filter: filter,
                  intensity: intensity,
                  opaque: opaque,
                  child: Row(
                    children: [
                      for (final rgb in _samples)
                        SizedBox(
                          width: 10,
                          height: 10,
                          child: ColoredBox(
                            color: Color.fromARGB(255, rgb[0], rgb[1], rgb[2]),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = (await tester.runAsync(
        () => boundary.toImage(pixelRatio: 1),
      ))!;
      final bytes = (await tester.runAsync(
        () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
      ))!;
      for (var i = 0; i < _samples.length; i++) {
        final input = _samples[i];
        final expected = filter.transform.applyReferenceRgb8(
          input[0],
          input[1],
          input[2],
          intensity: intensity,
        );
        final offset = (5 * 70 + i * 10 + 5) * 4;
        for (var channel = 0; channel < 3; channel++) {
          expect(
            bytes.getUint8(offset + channel),
            intensity > 0 && intensity < 1
                ? closeTo(expected[channel], 1)
                : expected[channel],
            reason: '${filter.id} $intensity, $input, 채널 $channel',
          );
        }
        expect(bytes.getUint8(offset + 3), 255);
      }
      image.dispose();
    }
  });
  testWidgets('행렬은 straight RGB에서 처리하고 반투명 알파를 유지한다', (tester) async {
    final boundaryKey = GlobalKey();
    const alphas = [0, 64, 128, 255];
    const input = [128, 64, 192];
    for (final (filter, intensity) in [
      for (final filter in filmFilters)
        for (final intensity in [0.0, .01, .5, .9, .99, 1.0])
          (filter, intensity),
    ]) {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: RepaintBoundary(
              key: boundaryKey,
              child: SizedBox(
                width: 40,
                height: 10,
                child: FilmFilterEffect(
                  filter: filter,
                  intensity: intensity,
                  child: Row(
                    children: [
                      for (final alpha in alphas)
                        SizedBox(
                          width: 10,
                          height: 10,
                          child: ColoredBox(
                            color: Color.fromARGB(
                              alpha,
                              input[0],
                              input[1],
                              input[2],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = (await tester.runAsync(
        () => boundary.toImage(pixelRatio: 1),
      ))!;
      final bytes = (await tester.runAsync(
        () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
      ))!;
      final rgb = filter.transform.applyReferenceRgb8(
        input[0],
        input[1],
        input[2],
        intensity: intensity,
      );
      for (var i = 0; i < alphas.length; i++) {
        final offset = (5 * 40 + i * 10 + 5) * 4;
        expect(bytes.getUint8(offset + 3), alphas[i]);
        for (var channel = 0; channel < 3; channel++) {
          // 렌더러의 8비트 premultiplied 저장 반올림에는 최대 1 차이를 허용한다.
          expect(
            bytes.getUint8(offset + channel),
            closeTo(rgb[channel] * alphas[i] / 255, 1),
          );
        }
      }
      image.dispose();
    }
  });
}
