import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../models/film_filter.dart';
import '../models/zoom_keyframe.dart';
import 'photo_repository.dart';

/// 고정 RGB 변환과 디지털 줌 타임라인을 실제 MP4 프레임에 내보낸다.
/// 실패 시 원본 및 작업 명세를 영구 디렉터리에 보존한다.
class VideoProcessor {
  VideoProcessor({
    MethodChannel? channel,
    Future<Directory> Function()? directoryProvider,
  }) : _channel = channel ?? const MethodChannel('aeroll/video_effects'),
       _directoryProvider =
           directoryProvider ?? getApplicationDocumentsDirectory;

  final MethodChannel _channel;
  final Future<Directory> Function() _directoryProvider;
  final List<File> _ownedFiles = [];
  String? _recoverableInputPath;
  String? get recoverableInputPath => _recoverableInputPath;

  Future<String> process({
    required String inputPath,
    required FilmFilter filter,
    required double intensity,
    required List<ZoomKeyframe> zoomKeyframes,
  }) async {
    // 이전 실패 작업은 디스크에 남겨 복구할 수 있게 하고, 다음 성공 시 지우지 않는다.
    _ownedFiles.clear();
    _recoverableInputPath = null;
    if (!intensity.isFinite ||
        intensity < 0 ||
        intensity > 1 ||
        zoomKeyframes.isEmpty) {
      throw const PhotoStorageException('영상 효과 설정이 올바르지 않습니다.');
    }
    var previousTime = -1;
    if (zoomKeyframes.first.timeMs != 0) {
      throw const PhotoStorageException('영상 줌 타임라인은 0ms에서 시작해야 합니다.');
    }
    for (final keyframe in zoomKeyframes) {
      if (keyframe.timeMs < previousTime ||
          keyframe.timeMs < 0 ||
          !keyframe.digitalScale.isFinite ||
          keyframe.digitalScale < 1) {
        throw const PhotoStorageException('영상 줌 타임라인이 올바르지 않습니다.');
      }
      previousTime = keyframe.timeMs;
    }
    final hasFilter = !filter.isOriginal && intensity > 0;
    if (!hasFilter && zoomKeyframes.every((k) => k.digitalScale == 1)) {
      return inputPath;
    }
    final root = await _directoryProvider();
    final directory = await Directory('${root.path}/aeroll_video_processing')
        .create(recursive: true);
    final prefix = '${directory.path}/${DateTime.now().microsecondsSinceEpoch}';
    final source = await File(inputPath).copy('${prefix}_source.mp4');
    _recoverableInputPath = source.path;
    _ownedFiles.add(source);
    final output = File('${prefix}_filtered.mp4');
    _ownedFiles.add(output);
    final job = File('${prefix}_job.json');
    _ownedFiles.add(job);
    final arguments = <String, Object?>{
      'inputPath': source.path,
      'outputPath': output.path,
      'rgbTransform': hasFilter
          ? {
              'slope': filter.transform.slope,
              'offsets': filter.transform.offsets,
              'intensity': intensity,
            }
          : null,
      'zoomKeyframes': zoomKeyframes.map((k) => k.toJson()).toList(),
    };
    final recovery = <String, Object?>{
      ...arguments,
      'filterId': filter.id,
      'filterName': filter.name,
      'colorSpace': 'gamma-encoded-sRGB',
      'stage': 'preparingTransform',
    };
    var jobSaved = false;
    try {
      // 출력 시작 전 재시도에 필요한 원본과 변환 정의를 기록한다.
      await job.writeAsString(jsonEncode(recovery), flush: true);
      jobSaved = true;
      // 최초 복구 명세를 잘라 쓰지 않고 새 파일을 완성한 뒤 교체한다.
      final readyJob = File('${job.path}.ready');
      _ownedFiles.add(readyJob);
      await readyJob.writeAsString(
        jsonEncode({...recovery, ...arguments, 'stage': 'readyToExport'}),
        flush: true,
      );
      await readyJob.rename(job.path);
      await _channel.invokeMethod<String>('exportVideo', arguments);
      if (!await output.exists() || await output.length() == 0) {
        throw const PhotoStorageException('영상 처리 결과가 비어 있습니다.');
      }
      return output.path;
    } catch (_) {
      // 처리하지 못한 원본을 필터가 적용된 영상으로 저장하지 않는다.
      if (!jobSaved) {
        throw const PhotoStorageException(
          '영상 처리에 실패했습니다. 복구용 원본은 보존했지만 작업 정보를 기록하지 못했습니다.',
        );
      }
      throw const PhotoStorageException(
        '영상 필터·줌 처리에 실패했습니다. 복구용 원본과 작업 정보는 보존했습니다.',
      );
    }
  }

  /// 기기 앨범 저장까지 성공한 뒤에만 작업 원본과 중간 파일을 정리한다.
  Future<void> completeSuccessfulSave() async {
    for (final file in _ownedFiles) {
      try {
        if (await file.exists()) await file.delete();
      } on FileSystemException {
        // 저장된 결과는 유지하고 중간 파일 정리 실패만 허용한다.
      }
    }
    _ownedFiles.clear();
    _recoverableInputPath = null;
  }
}
