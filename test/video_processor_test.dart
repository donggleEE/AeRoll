import 'dart:io';
import 'dart:convert';

import 'package:aeroll/models/film_filter.dart';
import 'package:aeroll/models/zoom_keyframe.dart';
import 'package:aeroll/services/photo_repository.dart';
import 'package:aeroll/services/video_processor.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('aeroll/video_effects');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late File input;
  late VideoProcessor processor;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('aeroll_export_test_');
    input = File('${root.path}/original.mp4');
    await input.writeAsBytes([1, 2, 3, 4]);
    processor = VideoProcessor(
      channel: channel,
      directoryProvider: () async => root,
    );
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await root.delete(recursive: true);
  });
  test('채널에 공통 RGB 정의·줌 타임라인을 전달하고 저장 후에만 정리한다', () async {
    Map<dynamic, dynamic>? payload;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'exportVideo');
      payload = call.arguments as Map;
      expect(payload!.containsKey('overlayPath'), isFalse);
      final transform = payload!['rgbTransform'] as Map;
      expect(transform['slope'], filmFilters[1].transform.slope);
      expect(transform['offsets'], filmFilters[1].transform.offsets);
      expect(transform['intensity'], .5);
      expect(await File(payload!['inputPath'] as String).readAsBytes(), [
        1,
        2,
        3,
        4,
      ]);
      await File(payload!['outputPath'] as String).writeAsBytes([9, 8, 7]);
      return payload!['outputPath'];
    });
    const frames = [
      ZoomKeyframe(timeMs: 0, digitalScale: 1),
      ZoomKeyframe(timeMs: 120, digitalScale: 4),
    ];
    final result = await processor.process(
      inputPath: input.path,
      filter: filmFilters[1],
      intensity: .5,
      zoomKeyframes: frames,
    );
    expect(payload!['zoomKeyframes'], [
      {'timeMs': 0, 'digitalScale': 1.0},
      {'timeMs': 120, 'digitalScale': 4.0},
    ]);
    expect(await File(result).readAsBytes(), [9, 8, 7]);
    expect(await File(processor.recoverableInputPath!).exists(), isTrue);
    await processor.completeSuccessfulSave();
    expect(await File(result).exists(), isFalse);
    expect(processor.recoverableInputPath, isNull);
    expect(await input.exists(), isTrue);
  });
  test('원본이고 확대가 없는 경우에만 네이티브 재출력을 생략한다', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      final args = call.arguments as Map;
      await File(args['outputPath'] as String).writeAsBytes([9]);
      return args['outputPath'];
    });
    final result = await processor.process(
      inputPath: input.path,
      filter: filmFilters.first,
      intensity: 1,
      zoomKeyframes: const [ZoomKeyframe(timeMs: 0, digitalScale: 1)],
    );
    expect(result, input.path);
    expect(calls, 0);
    expect(
      await processor.process(
        inputPath: input.path,
        filter: filmFilters.last,
        intensity: 0,
        zoomKeyframes: const [ZoomKeyframe(timeMs: 0, digitalScale: 1)],
      ),
      input.path,
    );
    expect(calls, 0);
    await processor.process(
      inputPath: input.path,
      filter: filmFilters.first,
      intensity: 1,
      zoomKeyframes: const [ZoomKeyframe(timeMs: 0, digitalScale: 2)],
    );
    expect(calls, 1);
  });
  test('출력 오류는 원본과 작업 명세를 보존하고 다음 성공의 정리가 이전 실패를 지우지 않는다', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'export_failed'),
    );
    await expectLater(
      processor.process(
        inputPath: input.path,
        filter: filmFilters.last,
        intensity: 1,
        zoomKeyframes: const [ZoomKeyframe(timeMs: 0, digitalScale: 1)],
      ),
      throwsA(isA<PhotoStorageException>()),
    );
    final recovery = File(processor.recoverableInputPath!);
    final jobs = await Directory('${root.path}/aeroll_video_processing')
        .list()
        .where((file) => file.path.endsWith('_job.json'))
        .toList();
    expect(jobs.length, 1);
    expect(await recovery.readAsBytes(), [1, 2, 3, 4]);
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map;
      await File(args['outputPath'] as String).writeAsBytes([8]);
      return args['outputPath'];
    });
    await processor.process(
      inputPath: input.path,
      filter: filmFilters.last,
      intensity: 1,
      zoomKeyframes: const [ZoomKeyframe(timeMs: 0, digitalScale: 1)],
    );
    await processor.completeSuccessfulSave();
    expect(await recovery.exists(), isTrue);
    expect(await jobs.single.exists(), isTrue);
  });
  test('네이티브 성공 응답만 있고 출력 파일이 없으면 성공으로 반환하지 않는다', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => (call.arguments as Map)['outputPath'],
    );
    await expectLater(
      processor.process(
        inputPath: input.path,
        filter: filmFilters.last,
        intensity: 1,
        zoomKeyframes: const [ZoomKeyframe(timeMs: 0, digitalScale: 1)],
      ),
      throwsA(isA<PhotoStorageException>()),
    );
    expect(await File(processor.recoverableInputPath!).exists(), isTrue);
  });
  test('타임라인은 0ms 시작과 순서·유효 확대를 검증한다', () async {
    for (final frames in [
      <ZoomKeyframe>[],
      const [ZoomKeyframe(timeMs: 2, digitalScale: 1)],
      const [ZoomKeyframe(timeMs: 0, digitalScale: .5)],
      const [
        ZoomKeyframe(timeMs: 0, digitalScale: 1),
        ZoomKeyframe(timeMs: -1, digitalScale: 1),
      ],
    ]) {
      await expectLater(
        processor.process(
          inputPath: input.path,
          filter: filmFilters.first,
          intensity: 1,
          zoomKeyframes: frames,
        ),
        throwsA(isA<PhotoStorageException>()),
      );
    }
  });
  test('cold 출력 실패에도 세 층에서 유도한 변환 정의와 복구 원본을 남긴다', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map;
      expect(args['rgbTransform'], {
        'slope': filmFilters.last.transform.slope,
        'offsets': filmFilters.last.transform.offsets,
        'intensity': 1.0,
      });
      throw PlatformException(code: 'export_failed');
    });
    await expectLater(
      processor.process(
        inputPath: input.path,
        filter: filmFilters.last,
        intensity: 1,
        zoomKeyframes: const [ZoomKeyframe(timeMs: 0, digitalScale: 1)],
      ),
      throwsA(isA<PhotoStorageException>()),
    );
    expect(await File(processor.recoverableInputPath!).exists(), isTrue);
    final jobs = await Directory('${root.path}/aeroll_video_processing')
        .list()
        .where((file) => file.path.endsWith('_job.json'))
        .toList();
    expect(jobs, hasLength(1));
    final job = jsonDecode(await File(jobs.single.path).readAsString()) as Map;
    expect(job['filterId'], 'cold');
    expect(job['colorSpace'], 'gamma-encoded-sRGB');
    expect(
      (job['rgbTransform'] as Map)['offsets'],
      filmFilters.last.transform.offsets,
    );
    expect(job.containsKey('filterAsset'), isFalse);
  });
}
