import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// 처리 전 원본과 촬영 시점의 설정만 보관한다. 완료 전에는 앨범 항목이 아니다.
class PhotoCaptureJob {
  PhotoCaptureJob(this.id, Map<String, Object?> settings)
    : settings = Map.unmodifiable(settings);
  final String id;
  final Map<String, Object?> settings;
}

class PhotoCaptureStore {
  PhotoCaptureStore({Future<Directory> Function()? directoryProvider})
    : _provider = directoryProvider ?? getApplicationDocumentsDirectory;
  final Future<Directory> Function() _provider;
  Future<Directory>? _root;
  static int _sequence = 0;

  PhotoCaptureJob create(Map<String, Object?> settings) => PhotoCaptureJob(
    '${DateTime.now().microsecondsSinceEpoch}_${_sequence++}',
    settings,
  );

  Future<Directory> _directory() => _root ??=
      (() async {
        final root = await _provider();
        return Directory('${root.path}/aeroll_photo_jobs')
            .create(recursive: true);
      })().catchError((Object error, StackTrace stack) {
        _root = null;
        Error.throwWithStackTrace(error, stack);
      });

  Future<Directory> _jobDirectory(PhotoCaptureJob job) async {
    if (!RegExp(r'^\d+_\d+$').hasMatch(job.id)) {
      throw const FormatException('복구 사진 ID가 올바르지 않습니다.');
    }
    return Directory('${(await _directory()).path}/${job.id}');
  }

  Future<void> stage(PhotoCaptureJob job, Uint8List bytes) async {
    final directory = await (await _jobDirectory(job)).create(recursive: true);
    await File('${directory.path}/source').writeAsBytes(bytes, flush: true);
    final draft = File('${directory.path}/job.pending');
    await draft.writeAsString(jsonEncode(job.settings), flush: true);
    await draft.rename('${directory.path}/job.json');
  }

  Future<Uint8List> read(PhotoCaptureJob job) async =>
      File('${(await _jobDirectory(job)).path}/source').readAsBytes();

  Future<List<PhotoCaptureJob>> pending() async {
    final jobs = <PhotoCaptureJob>[];
    await for (final directory in (await _directory()).list()) {
      if (directory is! Directory) continue;
      final id = directory.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (!RegExp(r'^\d+_\d+$').hasMatch(id)) continue;
      try {
        final source = File('${directory.path}/source');
        final metadata = File('${directory.path}/job.json');
        if (!await source.exists() || await source.length() == 0) continue;
        final settings = jsonDecode(await metadata.readAsString()) as Map;
        jobs.add(PhotoCaptureJob(id, Map<String, Object?>.from(settings)));
      } on FileSystemException {
        // 영구 기록이 끝나기 전 중단된 작업은 완성된 복구로 안내하지 않는다.
      } on FormatException {
        // 손상된 작업 하나가 다른 원본의 복구를 막지 않는다.
      } on TypeError {
        // 외부에서 변경된 명세를 실행하지 않는다.
      }
    }
    jobs.sort((a, b) => a.id.compareTo(b.id));
    return jobs;
  }

  Future<void> complete(PhotoCaptureJob job) async {
    final directory = await _jobDirectory(job);
    // 정해진 파일만 정리한다. 임의 경로나 재귀 삭제를 사용하지 않는다.
    for (final name in ['job.json', 'job.pending', 'source']) {
      final file = File('${directory.path}/$name');
      if (await file.exists()) await file.delete();
    }
    if (await directory.exists()) await directory.delete();
  }
}
