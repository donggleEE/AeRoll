import 'dart:io';
import 'dart:typed_data';

import 'package:aeroll/services/photo_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('aeroll_repository_test_');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('앨범 저장 후 새 저장소 인스턴스에서도 최신 사진부터 조회한다', () async {
    final written = <String>[];
    final repository = PhotoRepository(
      directoryProvider: () async => root,
      galleryWriter: (path) async {
        expect(await File(path).readAsBytes(), [1, 2, 3]);
        written.add(path);
      },
    );
    expect(await repository.listPhotos(), isEmpty);
    final first = await repository.savePhoto(
      bytes: Uint8List.fromList([1, 2, 3]),
      filterName: '원본',
    );
    final second = await repository.savePhoto(
      bytes: Uint8List.fromList([1, 2, 3]),
      filterName: '필름 빛',
    );
    final restarted = PhotoRepository(directoryProvider: () async => root);
    final photos = await restarted.listPhotos();
    expect(written, [first.path, second.path]);
    expect(photos.map((photo) => photo.id), [second.id, first.id]);
    expect(photos.first.filterName, '필름 빛');
    expect(photos.first.path, second.path);
  });

  test('실제 앨범 저장 실패는 성공 항목과 임시 파일을 남기지 않는다', () async {
    final repository = PhotoRepository(
      directoryProvider: () async => root,
      galleryWriter: (_) async => throw const PhotoStorageException('권한 거부'),
    );
    await expectLater(
      repository.savePhoto(bytes: Uint8List.fromList([1]), filterName: '원본'),
      throwsA(isA<PhotoStorageException>()),
    );
    expect(await repository.listPhotos(), isEmpty);
    expect(
      await Directory('${root.path}/aeroll_photos').list().toList(),
      isEmpty,
    );
  });

  test('손상된 메타데이터와 사라진 사본을 건너뛴다', () async {
    final repository = PhotoRepository(
      directoryProvider: () async => root,
      galleryWriter: (_) async {},
    );
    final missing = await repository.savePhoto(
      bytes: Uint8List.fromList([1]),
      filterName: '원본',
    );
    final valid = await repository.savePhoto(
      bytes: Uint8List.fromList([1]),
      filterName: '필름 빛',
    );
    await File(missing.path).delete();
    await File('${root.path}/aeroll_photos/broken.json')
        .writeAsString('{broken');
    expect((await repository.listPhotos()).single.id, valid.id);
  });
}
