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
  }) : _directoryProvider =
           directoryProvider ?? getApplicationDocumentsDirectory,
       _galleryWriter = galleryWriter ?? _writeToGallery;

  final Future<Directory> Function() _directoryProvider;
  final GalleryWriter _galleryWriter;
  int _sequence = 0;

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

  Future<SavedPhoto> savePhoto({
    required Uint8List bytes,
    required String filterName,
  }) async {
    final directory = await _directory();
    final now = DateTime.now();
    final id = '${now.microsecondsSinceEpoch}_${_sequence++}';
    final photo = SavedPhoto(
      id: id,
      path: '${directory.path}/$id.jpg',
      createdAt: now,
      filterName: filterName,
    );
    final image = File(photo.path);
    final metadata = File('${directory.path}/$id.json');
    final pendingMetadata = File('${metadata.path}.pending');
    var gallerySaved = false;
    // 갤러리 저장 전 로컬 파일 및 메타데이터 쓰기 실패를 먼저 감지한다.
    try {
      await image.writeAsBytes(bytes, flush: true);
      await pendingMetadata.writeAsString(
        jsonEncode(photo.toJson()),
        flush: true,
      );
      await _galleryWriter(photo.path);
      gallerySaved = true;
      await pendingMetadata.rename(metadata.path);
      return photo;
    } catch (error) {
      if (gallerySaved) {
        // 기기 앨범에는 저장된 상태다. 사본을 보존하고 부분 실패를 정확히 알린다.
        throw const PhotoStorageException(
          '기기 앨범에는 저장했지만 앱 사진 목록을 갱신하지 못했습니다. 기기 앨범에서 사진을 확인해 주세요.',
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
        throw PhotoStorageException(switch (error.type) {
          GalExceptionType.accessDenied =>
            '사진 저장 권한이 거부되었습니다. 설정에서 권한을 확인해 주세요.',
          GalExceptionType.notEnoughSpace =>
            '저장 공간이 부족합니다. 공간을 확보한 뒤 다시 촬영해 주세요.',
          GalExceptionType.notSupportedFormat => '사진 형식을 기기 앨범에서 지원하지 않습니다.',
          GalExceptionType.unexpected => '기기 앨범에 저장하지 못했습니다. 다시 시도해 주세요.',
        });
      }
      throw const PhotoStorageException('사진을 저장하지 못했습니다. 저장 공간과 권한을 확인해 주세요.');
    }
  }

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
        final path = '${directory.path}/$id.jpg';
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
