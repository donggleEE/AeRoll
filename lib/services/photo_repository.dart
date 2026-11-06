import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

import '../models/saved_photo.dart';

typedef GalleryWriter = Future<void> Function(String path);

/// 기기 앨범 저장과 앱 전용 영구 사본을 함께 관리한다.
/// 앱 갤러리는 앱에서 촬영한 사본만 조회하므로 전체 사진 읽기 권한이 없다.
class PhotoRepository {
  PhotoRepository({
    Future<Directory> Function()? directoryProvider,
    GalleryWriter? galleryWriter,
    GalleryWriter? videoGalleryWriter,
  }) : _directoryProvider =
           directoryProvider ?? getApplicationDocumentsDirectory,
       _galleryWriter = galleryWriter ?? _writeToGallery,
       _videoGalleryWriter = videoGalleryWriter ?? _writeVideoToGallery;

  final Future<Directory> Function() _directoryProvider;
  final GalleryWriter _galleryWriter;
  final GalleryWriter _videoGalleryWriter;
  int _sequence = 0;
  Map<String, int> lastSaveTimings = const {};

  Future<Directory> _directory() async {
    final root = await _directoryProvider();
    return Directory('${root.path}/aeroll_photos').create(recursive: true);
  }

  static Future<void> _writeToGallery(String path) async {
    if (!await Gal.hasAccess() && !await Gal.requestAccess()) {
      throw const PhotoStorageException('사진 저장 권한이 필요합니다. 설정에서 권한을 허용해 주세요.');
    }
    await Gal.putImage(path);
  }

  static Future<void> _writeVideoToGallery(String path) async {
    if (!await Gal.hasAccess() && !await Gal.requestAccess()) {
      throw const PhotoStorageException('영상 저장 권한이 필요합니다. 설정에서 권한을 허용해 주세요.');
    }
    await Gal.putVideo(path);
  }

  Future<SavedPhoto> savePhoto({
    required Uint8List bytes,
    required String filterName,
    String? captureId,
  }) => _saveMedia(bytes: bytes, filterName: filterName, captureId: captureId);

  /// 같은 작업 ID의 준비된 파일을 재사용해 필터·JPEG 처리를 반복하지 않는다.
  Future<SavedPhoto?> retryPreparedPhoto(String id) async {
    if (!RegExp(r'^\d+_\d+$').hasMatch(id)) return null;
    final directory = await _directory();
    final committed = File('${directory.path}/$id.json');
    final pending = File('${committed.path}.pending');
    if (!await File('${directory.path}/$id.jpg').exists()) return null;
    final metadata = await committed.exists() ? committed : pending;
    if (!await metadata.exists()) return null;
    final data =
        jsonDecode(await metadata.readAsString()) as Map<String, dynamic>;
    final photo = SavedPhoto.fromJson(data, path: '${directory.path}/$id.jpg');
    if (await committed.exists()) return photo;
    final clock = Stopwatch()..start();
    if (data['albumConfirmed'] != true) {
      try {
        await _galleryWriter(photo.path);
      } on GalException catch (error) {
        throw _galleryFailure(error);
      }
      data['albumConfirmed'] = true;
      await pending.writeAsString(jsonEncode(data), flush: true);
    }
    lastSaveTimings = {'albumSave': clock.elapsedMicroseconds};
    await pending.rename(committed.path);
    return photo;
  }

  /// MP4 파일은 전체 바이트를 메모리에 읽지 않고 앱 사본으로 복사한다.
  Future<SavedPhoto> saveVideo({
    required String path,
    String filterName = '원본 영상',
  }) => _saveMedia(sourcePath: path, filterName: filterName, isVideo: true);

  Future<SavedPhoto> _saveMedia({
    Uint8List? bytes,
    String? sourcePath,
    required String filterName,
    bool isVideo = false,
    String? captureId,
  }) async {
    if (captureId != null && !RegExp(r'^\d+_\d+$').hasMatch(captureId)) {
      throw const PhotoStorageException('촬영 작업 ID가 올바르지 않습니다.');
    }
    final clock = Stopwatch()..start();
    final timings = <String, int>{};
    void mark(String stage) {
      timings[stage] = clock.elapsedMicroseconds;
      clock.reset();
      lastSaveTimings = Map.unmodifiable(timings);
    }

    final directory = await _directory();
    final now = DateTime.now();
    final id = captureId ?? '${now.microsecondsSinceEpoch}_${_sequence++}';
    final photo = SavedPhoto(
      id: id,
      path: '${directory.path}/$id.${isVideo ? 'mp4' : 'jpg'}',
      createdAt: now,
      filterName: filterName,
      isVideo: isVideo,
    );
    final image = File(photo.path);
    final metadata = File('${directory.path}/$id.json');
    final pendingMetadata = File('${metadata.path}.pending');
    var gallerySaved = false;
    // 갤러리 저장 전 로컬 파일 및 메타데이터 쓰기 실패를 먼저 감지한다.
    try {
      if (isVideo) {
        final source = File(sourcePath!);
        if (!await source.exists() || await source.length() == 0) {
          throw const PhotoStorageException('녹화한 영상 파일이 비어 있거나 사라졌습니다.');
        }
        await source.copy(image.path);
      } else {
        await image.writeAsBytes(bytes!, flush: true);
      }
      mark('fileWrite');
      await pendingMetadata.writeAsString(
        jsonEncode(photo.toJson()),
        flush: true,
      );
      mark('metadataPrepare');
      await (isVideo ? _videoGalleryWriter : _galleryWriter)(photo.path);
      gallerySaved = true;
      mark('albumSave');
      await pendingMetadata.writeAsString(
        jsonEncode({...photo.toJson(), 'albumConfirmed': true}),
        flush: true,
      );
      await pendingMetadata.rename(metadata.path);
      mark('metadataCommit');
      return photo;
    } catch (error) {
      if (gallerySaved) {
        // 기기 앨범에는 저장된 상태다. 사본을 보존하고 부분 실패를 정확히 알린다.
        throw const PhotoStorageException(
          '기기 앨범에는 저장했지만 앱 사진 목록을 갱신하지 못했습니다. 기기 앨범에서 사진을 확인해 주세요.',
        );
      }
      if (!isVideo && captureId != null && await image.exists()) {
        // 원본 작업과 완성된 JPEG를 모두 유지하고 성공 목록에는 넣지 않는다.
        if (error is PhotoStorageException) rethrow;
        if (error is GalException) throw _galleryFailure(error);
        throw const PhotoStorageException(
          '사진 저장에 실패했습니다. 원본을 보관했어요. 재시도해 주세요.',
        );
      }
      if (isVideo && await image.exists() && await image.length() > 0) {
        // 녹화는 다시 촬영할 수 없는 순간일 수 있으므로 앨범 오류에도 사본을 보존한다.
        final recovery = SavedPhoto(
          id: id,
          path: photo.path,
          createdAt: now,
          filterName: filterName,
          isVideo: true,
          isInDeviceAlbum: false,
        );
        try {
          await metadata.writeAsString(
            jsonEncode(recovery.toJson()),
            flush: true,
          );
          if (await pendingMetadata.exists()) await pendingMetadata.delete();
        } on FileSystemException {
          throw const PhotoStorageException(
            '영상 앨범 저장에 실패했습니다. 복구용 앱 사본은 보존했습니다.',
          );
        }
        throw const PhotoStorageException(
          '기기 앨범에 저장하지 못했습니다. 영상은 앱 갤러리에 보관했습니다.',
        );
      }
      // 실패한 촬영은 앱 갤러리에도 성공 결과로 남기지 않는다.
      for (final file in [pendingMetadata, metadata, image]) {
        try {
          if (await file.exists()) await file.delete();
        } on FileSystemException {
          // 정리 실패가 실제 저장 오류를 가리지 않게 한다.
        }
      }
      if (error is PhotoStorageException) rethrow;
      if (error is GalException) {
        throw _galleryFailure(error);
      }
      throw const PhotoStorageException('사진을 저장하지 못했습니다. 저장 공간과 권한을 확인해 주세요.');
    }
  }

  static PhotoStorageException _galleryFailure(GalException error) =>
      PhotoStorageException(switch (error.type) {
        GalExceptionType.accessDenied => '사진 저장 권한이 거부되었습니다. 설정에서 권한을 확인해 주세요.',
        GalExceptionType.notEnoughSpace => '저장 공간이 부족합니다. 공간을 확보한 뒤 재시도해 주세요.',
        GalExceptionType.notSupportedFormat => '사진 형식을 기기 앨범에서 지원하지 않습니다.',
        GalExceptionType.unexpected => '기기 앨범에 저장하지 못했습니다. 다시 시도해 주세요.',
      });

  Future<List<SavedPhoto>> listPhotos() async {
    final directory = await _directory();
    final photos = <SavedPhoto>[];
    await for (final file in directory.list()) {
      if (file is! File || !file.path.endsWith('.json')) continue;
      try {
        final data =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        // 저장했던 절대 경로는 재설치/백업 복원에서 바뀔 수 있어 재구성한다.
        final id = data['id'] as String;
        if (!RegExp(r'^\d+_\d+$').hasMatch(id)) continue;
        final isVideo = data['isVideo'] as bool? ?? false;
        final path = '${directory.path}/$id.${isVideo ? 'mp4' : 'jpg'}';
        if (await File(path).exists()) {
          photos.add(SavedPhoto.fromJson(data, path: path));
        }
      } on FormatException {
        // 손상된 항목 하나가 나머지 사진 조회를 막지 않게 한다.
      } on TypeError {
        // 이전 형식 또는 잘못된 메타데이터는 건너뛴다.
      } on FileSystemException {
        // 조회 중 사라지거나 읽을 수 없게 된 파일은 건너뛴다.
      }
    }
    photos.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return photos;
  }
}

class PhotoStorageException implements Exception {
  const PhotoStorageException(this.message);
  final String message;

  @override
  String toString() => message;
}
