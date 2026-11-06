import 'dart:async';
import 'dart:isolate';

import 'dart:typed_data';

import 'photo_compositor.dart';

/// 촬영마다 isolate를 새로 만들지 않는 전용 RGB 처리기.
/// CameraSession의 유한 직렬 큐가 입력 개수와 메모리를 제한한다.
class PhotoProcessor {
  Map<String, int> lastTimings = const {};
  Uint8List? lastThumbnailBytes;
  final _responses = ReceivePort();
  final _requests = <int, Completer<Uint8List>>{};
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
        if (message[1] is Map) {
          final result = message[1] as Map;
          lastTimings = Map<String, int>.from(result['timings'] as Map);
          lastThumbnailBytes = (result['thumbnail'] as TransferableTypedData?)
              ?.materialize()
              .asUint8List();
          request?.complete(
            (result['bytes'] as TransferableTypedData)
                .materialize()
                .asUint8List(),
          );
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

  Future<void> preload() => _start();

  Future<Uint8List> process({
    required Uint8List photoBytes,
    String filterId = 'original',
    bool lossless = false,
    required double intensity,
    required double frameAspectRatio,
    required bool mirrorHorizontally,
    double digitalScale = 1,
  }) async {
    await _start();
    final transferClock = Stopwatch()..start();
    final transferred = TransferableTypedData.fromList([photoBytes]);
    final transferIn = transferClock.elapsedMicroseconds;
    final result = await _send({
      'photoBytes': transferred,
      'transferIn': transferIn,
      'filterId': filterId,
      'lossless': lossless,
      'intensity': intensity,
      'frameAspectRatio': frameAspectRatio,
      'mirrorHorizontally': mirrorHorizontally,
      'digitalScale': digitalScale,
    });
    return result;
  }

  Future<Uint8List> _send(Map<String, Object?> payload) {
    if (_closed) throw StateError('사진 처리기가 종료되었습니다.');
    if (_requests.length >= 3) throw StateError('사진 처리 대기열이 가득 찼습니다.');
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
  }
}

void _photoWorker(SendPort responses) {
  final requests = ReceivePort();
  responses.send(requests.sendPort);
  requests.listen((dynamic message) {
    final id = message[0] as int;
    final payload = message[1] as Map<String, Object?>;
    try {
      payload['photoBytes'] = (payload['photoBytes'] as TransferableTypedData)
          .materialize()
          .asUint8List();
      final timings = <String, int>{};
      timings['transferIn'] = payload['transferIn'] as int? ?? 0;
      Uint8List? thumbnail;
      final bytes = compositePhoto(
        photoBytes: payload['photoBytes']! as Uint8List,
        filterId: payload['filterId'] as String? ?? 'original',
        lossless: payload['lossless'] as bool? ?? false,
        intensity: payload['intensity']! as double,
        frameAspectRatio: payload['frameAspectRatio']! as double,
        mirrorHorizontally: payload['mirrorHorizontally']! as bool,
        digitalScale: payload['digitalScale'] as double? ?? 1,
        timings: timings,
        onThumbnail: (bytes) => thumbnail = bytes,
      );
      final transferClock = Stopwatch()..start();
      final outputTransfer = TransferableTypedData.fromList([bytes]);
      final thumbnailTransfer = thumbnail == null
          ? null
          : TransferableTypedData.fromList([thumbnail!]);
      timings['transferOut'] = transferClock.elapsedMicroseconds;
      responses.send([
        id,
        {
          'bytes': outputTransfer,
          'thumbnail': thumbnailTransfer,
          'timings': timings,
        },
      ]);
    } catch (error) {
      responses.send([id, error.toString()]);
    }
  });
}
