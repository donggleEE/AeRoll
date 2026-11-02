import 'dart:async';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import '../models/film_filter.dart';
import 'photo_compositor.dart';

/// 촬영마다 isolate와 PNG 디코더를 새로 만들지 않는 전용 처리기.
/// CameraSession의 유한 직렬 큐가 입력 개수와 메모리를 제한한다.
class PhotoProcessor {
  final _responses = ReceivePort();
  final _requests = <int, Completer<Uint8List>>{};
  final _assets = <String, Future<Uint8List>>{};
  final _sentAssets = <String>{};
  Isolate? _isolate;
  SendPort? _sendPort;
  Future<void>? _starting;
  StreamSubscription<dynamic>? _subscription;
  int _nextId = 0;
  bool _closed = false;

  Future<void> _start() => _starting ??= _startWorker();

  Future<void> _startWorker() async {
    if (_closed) throw StateError('사진 처리기가 종료되었습니다.');
    final ready = Completer<void>();
    _subscription = _responses.listen((dynamic message) {
      if (message is SendPort) {
        _sendPort = message;
        ready.complete();
      } else if (message is List && message.length == 2 && message[0] is int) {
        final request = _requests.remove(message[0] as int);
        if (message[1] is Uint8List) {
          request?.complete(message[1] as Uint8List);
        } else {
          request?.completeError(StateError(message[1].toString()));
        }
      } else if (!_closed) {
        final error = StateError('사진 처리 작업이 중단되었습니다.');
        if (!ready.isCompleted) ready.completeError(error);
        for (final request in _requests.values) {
          request.completeError(error);
        }
        _requests.clear();
        _closed = true;
      }
    });
    _isolate = await Isolate.spawn(
      _photoWorker,
      _responses.sendPort,
      onError: _responses.sendPort,
      onExit: _responses.sendPort,
    );
    await ready.future;
  }

  Future<Uint8List> _loadAsset(String asset) => _assets.putIfAbsent(
    asset,
    () async {
      try {
        final data = await rootBundle.load(asset);
        return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } catch (_) {
        _assets.remove(asset);
        rethrow;
      }
    },
  );

  Future<void> preload() async {
    await _start();
    for (final filter in filmFilters) {
      final asset = filter.assetPath;
      if (asset == null) continue;
      if (_sentAssets.contains(asset)) continue;
      await _send({
        'overlayKey': asset,
        'overlayBytes': await _loadAsset(asset),
      });
      _sentAssets.add(asset);
    }
  }

  Future<Uint8List> process({
    required Uint8List photoBytes,
    String? overlayAsset,
    required double intensity,
    required double frameAspectRatio,
    required bool mirrorHorizontally,
  }) async {
    await _start();
    final overlay = overlayAsset == null || _sentAssets.contains(overlayAsset)
        ? null
        : await _loadAsset(overlayAsset);
    final result = await _send({
      'photoBytes': photoBytes,
      'overlayKey': overlayAsset,
      'overlayBytes': overlay,
      'intensity': intensity,
      'frameAspectRatio': frameAspectRatio,
      'mirrorHorizontally': mirrorHorizontally,
    });
    if (overlayAsset != null) _sentAssets.add(overlayAsset);
    return result;
  }

  Future<Uint8List> _send(Map<String, Object?> payload) {
    if (_closed) throw StateError('사진 처리기가 종료되었습니다.');
    final id = _nextId++;
    final completer = Completer<Uint8List>();
    _requests[id] = completer;
    _sendPort!.send([id, payload]);
    return completer.future;
  }

  Future<void> dispose() async {
    if (_starting != null) {
      try {
        await _starting;
      } catch (_) {
        // 시작 실패한 처리기도 포트는 정리한다.
      }
    }
    _closed = true;
    _isolate?.kill(priority: Isolate.immediate);
    await _subscription?.cancel();
    _responses.close();
    for (final request in _requests.values) {
      request.completeError(StateError('사진 처리기가 종료되었습니다.'));
    }
    _requests.clear();
    _assets.clear();
  }
}

void _photoWorker(SendPort responses) {
  final requests = ReceivePort();
  final overlays = <String, img.Image>{};
  responses.send(requests.sendPort);
  requests.listen((dynamic message) {
    final id = message[0] as int;
    final payload = message[1] as Map<String, Object?>;
    try {
      final key = payload['overlayKey'] as String?;
      final overlayBytes = payload['overlayBytes'] as Uint8List?;
      if (key != null && overlayBytes != null && !overlays.containsKey(key)) {
        final decoded = img.decodeImage(overlayBytes);
        if (decoded == null) throw const FormatException('필터를 읽을 수 없습니다.');
        overlays[key] = decoded;
      }
      if (payload['photoBytes'] == null) {
        responses.send([id, Uint8List(0)]);
        return;
      }
      if (key != null && !overlays.containsKey(key)) {
        throw const FormatException('필터가 준비되지 않았습니다.');
      }
      responses.send([
        id,
        compositePhoto(
          photoBytes: payload['photoBytes']! as Uint8List,
          decodedOverlay: key == null ? null : overlays[key],
          intensity: payload['intensity']! as double,
          frameAspectRatio: payload['frameAspectRatio']! as double,
          mirrorHorizontally: payload['mirrorHorizontally']! as bool,
        ),
      ]);
    } catch (error) {
      responses.send([id, error.toString()]);
    }
  });
}
