import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aeroll/services/photo_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('aeroll_video_test_');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  test('영상 사본과 실제 앨범 쓰기 함수 및 사진의 혼합 조회를 연결한다', () async {
    final source = File('${root.path}/input.mp4');
    await source.writeAsBytes([1, 2, 3, 4]);
    final writes = <String>[];
    final repository = PhotoRepository(
      directoryProvider: () async => root,
      galleryWriter: (_) async {},
      videoGalleryWriter: (path) async {
        expect(await File(path).readAsBytes(), [1, 2, 3, 4]);
        writes.add(path);
      },
    );
    await repository.savePhoto(
      bytes: Uint8List.fromList([1]),
      filterName: '원본',
    );
    final video = await repository.saveVideo(path: source.path);
    expect(video.isVideo, isTrue);
    expect(video.isInDeviceAlbum, isTrue);
    expect(video.path, endsWith('.mp4'));
    expect(writes, [video.path]);
    final restarted = PhotoRepository(directoryProvider: () async => root);
    final items = await restarted.listPhotos();
    expect(items.length, 2);
    expect(items.first.isVideo, isTrue);
    expect(items.last.isVideo, isFalse);
  });
  test('영상 앨범 저장이 실패하면 성공을 반환하지 않고 복구 사본임을 기록한다', () async {
    final source = File('${root.path}/input.mp4');
    await source.writeAsBytes([1, 2, 3]);
    final repository = PhotoRepository(
      directoryProvider: () async => root,
      videoGalleryWriter: (_) async =>
          throw const PhotoStorageException('권한 거부'),
    );
    await expectLater(
      repository.saveVideo(path: source.path),
      throwsA(isA<PhotoStorageException>()),
    );
    final recovered = (await repository.listPhotos()).single;
    expect(recovered.isVideo, isTrue);
    expect(recovered.isInDeviceAlbum, isFalse);
    expect(await File(recovered.path).readAsBytes(), [1, 2, 3]);
    expect(await source.exists(), isTrue);
  });
  test('예전 사진 JSON은 사진으로 읽고 비어 있는 영상은 저장하지 않는다', () async {
    final folder = await Directory('${root.path}/aeroll_photos').create();
    await File('${folder.path}/1_0.jpg').writeAsBytes([1]);
    await File('${folder.path}/1_0.json').writeAsString(
      jsonEncode({
        'id': '1_0',
        'createdAt': '2026-11-02T00:00:00Z',
        'filterName': '원본',
      }),
    );
    final repository = PhotoRepository(
      directoryProvider: () async => root,
      videoGalleryWriter: (_) async {},
    );
    final legacy = (await repository.listPhotos()).single;
    expect(legacy.isVideo, isFalse);
    expect(legacy.isInDeviceAlbum, isTrue);
    final empty = File('${root.path}/empty.mp4');
    await empty.create();
    await expectLater(
      repository.saveVideo(path: empty.path),
      throwsA(isA<PhotoStorageException>()),
    );
    expect((await repository.listPhotos()).length, 1);
  });
}
