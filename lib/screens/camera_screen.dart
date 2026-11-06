import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../controllers/camera_session.dart';
import '../controllers/level_controller.dart';
import '../models/film_filter.dart';
import '../models/saved_photo.dart';
import '../widgets/camera_level_indicator.dart';
import '../widgets/camera_settings_sheet.dart';
import '../widgets/camera_viewfinder.dart';
import '../widgets/film_filter_selector.dart';
import '../widgets/zoom_ruler.dart';
import '../widgets/preview_focus_point.dart';
import 'gallery_screen.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key, this.session, this.levelController});
  final CameraSession? session;
  final LevelController? levelController;

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  late final CameraSession _session;
  late final LevelController _level;
  late final Listenable _updates;
  FilmFilter _filter = filmFilters.last;
  PhotoFrameRatio _frameRatio = PhotoFrameRatio.wide;
  bool _gridEnabled = true;
  bool _galleryOpen = false;
  bool _changingMode = false;
  bool _recordingCommand = false;
  bool _flashVisible = false;
  Timer? _flashTimer;
  Timer? _recordingTimer;
  final Stopwatch _recordingWatch = Stopwatch();
  bool _wasRecording = false;
  String? _lastVideoId;
  String? _lastVideoError;
  String? _actionError;
  SavedPhoto? _latestPhoto;
  double _pinchStartZoom = 1;
  double _pinchReferenceScale = 1;
  bool _pinching = false;
  bool _zoomRulerVisible = false;
  Timer? _zoomRulerTimer;
  bool _rulerHeld = false;
  double _rulerDragZoom = 1;
  final Map<String, double> _filterIntensities = {};
  double get _intensity =>
      _filter.isOriginal ? 0 : (_filterIntensities[_filter.id] ?? 1);
  int _timerSeconds = 0;
  int? _countdown;
  Timer? _countdownTimer;
  Offset? _focusPosition;
  bool _focusVisible = false;
  Timer? _focusTimer;
  int _focusRequest = 0;
  int _pointerCount = 0;
  bool _multiTouch = false;
  bool get _controlsLocked => _locked || _countdown != null;

  bool get _locked =>
      _session.isRecording ||
      _session.isRecordingBusy ||
      _recordingCommand ||
      _changingMode;

  @override
  void initState() {
    super.initState();
    _session = widget.session ?? CameraSession();
    _level = widget.levelController ?? LevelController();
    _updates = Listenable.merge([_session, _level]);
    _session.addListener(_sessionChanged);
    WidgetsBinding.instance.addObserver(this);
    unawaited(_cameraAction(_session.initialize));
    unawaited(_refreshLatestPhoto());
  }

  void _sessionChanged() {
    if (!mounted) return;
    final savedPhoto = _session.lastSavedPhoto;
    if (savedPhoto != null && savedPhoto.id != _latestPhoto?.id) {
      setState(() => _latestPhoto = savedPhoto);
    }
    if (_session.isRecording && !_wasRecording) {
      _recordingWatch
        ..reset()
        ..start();
      _recordingTimer?.cancel();
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!_session.isRecording && _wasRecording) {
      _recordingWatch.stop();
      _recordingTimer?.cancel();
    }
    _wasRecording = _session.isRecording;
    final video = _session.lastSavedVideo;
    if (video != null && video.id != _lastVideoId) {
      _lastVideoId = video.id;
      setState(() => _latestPhoto = video);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.resumed) {
          _showMessage(
            video.isInDeviceAlbum
                ? '동영상을 기기 앨범에 저장했어요'
                : '기기 앨범 저장에 실패했어요. 앱 갤러리에 사본을 보관했어요.',
          );
        }
      });
    }
    final error = _session.errorMessage;
    if (_session.videoMode && error != null && error != _lastVideoError) {
      _lastVideoError = error;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showMessage(error);
      });
    } else if (error == null) {
      _lastVideoError = null;
    }
  }

  Future<void> _refreshLatestPhoto() async {
    try {
      final photos = await _session.repository.listPhotos();
      if (!mounted || photos.isEmpty) return;
      final latest = photos.first;
      if (_latestPhoto == null ||
          !latest.createdAt.isBefore(_latestPhoto!.createdAt)) {
        setState(() => _latestPhoto = latest);
      }
    } catch (_) {
      /* 갤러리 진입 시 오류와 재시도 방법을 안내한다. */
    }
  }

  Future<void> _cameraAction(Future<void> Function() action) async {
    try {
      await action();
      if (mounted) setState(() => _actionError = null);
    } catch (error) {
      if (mounted) {
        setState(() => _actionError = error.toString());
        _showMessage(error.toString());
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_galleryOpen) {
        unawaited(_cameraAction(_session.resume));
        unawaited(_level.resume());
      }
    } else {
      _cancelCountdown();
      _clearFocus();
      _zoomRulerTimer?.cancel();
      _pinching = false;
      _rulerHeld = false;
      _pointerCount = 0;
      _multiTouch = false;
      if (_zoomRulerVisible) setState(() => _zoomRulerVisible = false);
      unawaited(_cameraAction(_session.suspend));
      unawaited(_level.suspend());
    }
  }

  Future<void> _capture(double frameAspectRatio) async {
    if (!_session.canCapture || _galleryOpen || _locked || _session.videoMode) {
      return;
    }
    _session.notePhotoInput();
    unawaited(HapticFeedback.lightImpact().catchError((Object _) {}));
    _flashTimer?.cancel();
    setState(() => _flashVisible = true);
    _flashTimer = Timer(const Duration(milliseconds: 90), () {
      if (mounted) setState(() => _flashVisible = false);
    });
    try {
      final photo = await _session.capture(
        filter: _filter,
        intensity: _intensity,
        frameAspectRatio: frameAspectRatio,
      );
      if (!mounted) return;
      if (_latestPhoto?.id != photo.id) setState(() => _latestPhoto = photo);
    } catch (error) {
      if (mounted) _showMessage('사진을 저장하지 못했어요. $error');
    }
  }

  Future<void> _changeMode(bool video) async {
    _cancelCountdown();
    _clearFocus();
    if (_locked ||
        _session.isCapturing ||
        _session.isSwitchingCamera ||
        video == _session.videoMode) {
      return;
    }
    setState(() => _changingMode = true);
    try {
      await _session.setVideoMode(video);
    } catch (error) {
      if (mounted) _showMessage('촬영 모드를 바꾸지 못했어요. $error');
    } finally {
      if (mounted) setState(() => _changingMode = false);
    }
  }

  Future<void> _recordVideo() async {
    if (_recordingCommand || _session.isRecordingBusy || _changingMode) return;
    if (!_session.isRecording && !_session.canStartRecording) return;
    setState(() => _recordingCommand = true);
    unawaited(HapticFeedback.lightImpact().catchError((Object _) {}));
    try {
      if (_session.isRecording) {
        await _session.stopVideoRecording();
      } else {
        await _session.startVideoRecording(
          filter: _filter,
          intensity: _intensity,
        );
      }
    } catch (error) {
      if (mounted) _showMessage('동영상을 처리하지 못했어요. $error');
    } finally {
      if (mounted) setState(() => _recordingCommand = false);
    }
  }

  void _showMessage(String message) {
    void show() {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
    }

    // 초기화 오류가 첫 Scaffold 구성 중 전달되어도 안전하게 안내한다.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => show());
    } else {
      show();
    }
  }

  Future<void> _openGallery() async {
    _cancelCountdown();
    _clearFocus();
    if (_galleryOpen ||
        _locked ||
        _session.isCapturing ||
        _session.isSwitchingCamera) {
      return;
    }
    setState(() => _galleryOpen = true);
    await _cameraAction(_session.suspend);
    await _level.suspend();
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => GalleryScreen(repository: _session.repository),
      ),
    );
    if (!mounted) return;
    setState(() => _galleryOpen = false);
    unawaited(_refreshLatestPhoto());
    if (WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      await _cameraAction(_session.resume);
      await _level.resume();
    }
  }

  Future<void> _openSettings() async {
    _cancelCountdown();
    if (_locked) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CameraSettingsSheet(
        gridEnabled: _gridEnabled,
        levelEnabled: _level.enabled,
        frameRatio: _frameRatio,
        onGridChanged: (value) {
          if (mounted) setState(() => _gridEnabled = value);
        },
        onLevelChanged: (value) =>
            unawaited(_cameraAction(() => _level.setEnabled(value))),
        onRatioChanged: (value) {
          if (mounted) setState(() => _frameRatio = value);
        },
      ),
    );
  }

  void _showZoomRuler() {
    _zoomRulerTimer?.cancel();
    if (!_zoomRulerVisible) setState(() => _zoomRulerVisible = true);
  }

  void _finishPinch() {
    if (!_pinching) return;
    _pinching = false;
    _zoomRulerTimer?.cancel();
    _zoomRulerTimer = Timer(const Duration(seconds: 2), () {
      if (mounted && !_pinching && !_rulerHeld) {
        setState(() => _zoomRulerVisible = false);
      }
    });
  }

  void _scaleStart(ScaleStartDetails details) {
    if (_rulerHeld) return;
    _pinchStartZoom = _session.currentZoom;
    _pinchReferenceScale = 1;
    _pinching = details.pointerCount >= 2;
    if (_pinching) _showZoomRuler();
  }

  void _scaleUpdate(ScaleUpdateDetails details) {
    if (_rulerHeld) return;
    if (details.pointerCount < 2 ||
        _session.isCapturing ||
        _session.isInitializing ||
        _session.isSwitchingCamera) {
      _finishPinch();
      return;
    }
    if (!_pinching) {
      _pinching = true;
      _pinchStartZoom = _session.currentZoom;
      _pinchReferenceScale = details.scale;
    }
    _showZoomRuler();
    if (_pinchReferenceScale <= 0 || !details.scale.isFinite) return;
    final zoom = (_pinchStartZoom * details.scale / _pinchReferenceScale)
        .clamp(_session.minZoom, _session.maxZoom)
        .toDouble();
    unawaited(
      _session.setZoom(zoom).catchError((Object error) {
        if (mounted) _showMessage('줌을 조절하지 못했어요. $error');
      }),
    );
  }

  void _cancelCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    if (_countdown != null && mounted) setState(() => _countdown = null);
  }

  void _triggerCapture(double ratio) {
    if (_countdown != null) {
      _cancelCountdown();
      return;
    }
    if (!_session.canCapture || _locked || _galleryOpen) return;
    if (_timerSeconds == 0) {
      unawaited(_capture(ratio));
      return;
    }
    setState(() => _countdown = _timerSeconds);
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _countdown == null) return;
      if (_countdown! > 1) {
        setState(() => _countdown = _countdown! - 1);
      } else {
        _cancelCountdown();
        unawaited(_capture(ratio));
      }
    });
  }

  void _clearFocus() {
    _focusRequest++;
    _focusTimer?.cancel();
    if (mounted && _focusVisible) setState(() => _focusVisible = false);
  }

  Future<void> _focusAt(Offset position, Size viewport) async {
    if (_multiTouch ||
        _rulerHeld ||
        _pinching ||
        _controlsLocked ||
        _galleryOpen ||
        !_session.canSetFocus) {
      return;
    }
    final camera = _session.cameraController;
    final preview = camera?.value.previewSize;
    if (camera == null || preview == null) return;
    final value = camera.value;
    final orientation =
        value.previewPauseOrientation ??
        value.lockedCaptureOrientation ??
        value.deviceOrientation;
    final point = previewFocusPoint(
      position: position,
      viewport: viewport,
      previewSize: preview,
      orientation: orientation,
      // Android 플러그인의 deviceOrientation도 실제 display 회전에서 산출된다.
      meteringOrientation: value.deviceOrientation,
      fit: _session.videoMode ? BoxFit.contain : BoxFit.cover,
      digitalZoom: _session.previewDigitalZoom,
      mirrored: _session.isFrontCamera && _session.videoMode,
      isFrontCamera: _session.isFrontCamera,
      platformHandlesFrontMirror: defaultTargetPlatform != TargetPlatform.iOS,
    );
    if (point == null) return;
    _focusTimer?.cancel();
    final request = ++_focusRequest;
    setState(() {
      _focusPosition = position;
      _focusVisible = true;
    });
    try {
      final focused = await _session.focusAt(point);
      if (!focused && mounted && request == _focusRequest) {
        setState(() => _focusVisible = false);
        return;
      }
    } catch (error) {
      if (mounted && request == _focusRequest) {
        _showMessage('초점을 맞추지 못했어요. $error');
      }
    }
    if (!mounted || request != _focusRequest) return;
    _focusTimer = Timer(const Duration(milliseconds: 1100), () {
      if (mounted) setState(() => _focusVisible = false);
    });
  }

  void _releaseRuler() {
    _rulerHeld = false;
    _zoomRulerTimer?.cancel();
    _zoomRulerTimer = Timer(const Duration(seconds: 2), () {
      if (mounted && !_rulerHeld && !_pinching) {
        setState(() => _zoomRulerVisible = false);
      }
    });
  }

  void _dragRuler(DragUpdateDetails details) {
    if (_session.isCapturing ||
        _session.isInitializing ||
        _session.isSwitchingCamera) {
      return;
    }
    _rulerDragZoom = (_rulerDragZoom * math.exp(-details.delta.dy / 120))
        .clamp(_session.minZoom, _session.maxZoom)
        .toDouble();
    unawaited(
      _session.setZoom(_rulerDragZoom).catchError((Object error) {
        if (mounted) _showMessage('줌을 조절하지 못했어요. $error');
      }),
    );
  }

  double? _levelAngle(bool landscape) {
    var angle = _level.angleDegrees;
    if (angle == null) return null;
    if (landscape) angle += angle >= 0 ? -90 : 90;
    while (angle! > 90) {
      angle -= 180;
    }
    while (angle! < -90) {
      angle += 180;
    }
    return angle;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session.removeListener(_sessionChanged);
    _flashTimer?.cancel();
    _zoomRulerTimer?.cancel();
    _recordingTimer?.cancel();
    _countdownTimer?.cancel();
    _focusTimer?.cancel();
    if (widget.session == null) _session.dispose();
    if (widget.levelController == null) _level.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnnotatedRegion<SystemUiOverlayStyle>(
    value: SystemUiOverlayStyle.light.copyWith(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.black,
    ),
    child: Scaffold(
      backgroundColor: Colors.black,
      body: AnimatedBuilder(
        animation: _updates,
        builder: (context, _) => LayoutBuilder(
          builder: (context, constraints) {
            if (!constraints.hasBoundedWidth ||
                !constraints.hasBoundedHeight ||
                constraints.maxWidth <= 40 ||
                constraints.maxHeight <= 0) {
              return const SizedBox.shrink();
            }
            final size = constraints.biggest;
            final landscape = size.width > size.height;
            final aspectRatio = _session.videoMode
                ? (landscape ? 16 / 9 : 9 / 16)
                : _frameRatio.forSize(size);
            final frameSize = applyBoxFit(
              BoxFit.contain,
              Size(aspectRatio, 1),
              size,
            ).destination;
            final safe = MediaQuery.paddingOf(context);
            final sensorBusy =
                _session.isCapturing || _session.isSwitchingCamera;
            return Stack(
              fit: StackFit.expand,
              children: [
                Center(
                  child: AspectRatio(
                    key: const Key('capture-viewport'),
                    aspectRatio: aspectRatio,
                    child: GestureDetector(
                      key: const Key('viewfinder-zoom-gesture'),
                      behavior: HitTestBehavior.opaque,
                      onTapUp: (details) =>
                          unawaited(_focusAt(details.localPosition, frameSize)),
                      onScaleStart: _scaleStart,
                      onScaleUpdate: _scaleUpdate,
                      onScaleEnd: (_) => _finishPinch(),
                      child: Listener(
                        onPointerDown: (_) {
                          if (_pointerCount == 0) _multiTouch = false;
                          _pointerCount++;
                          if (_pointerCount > 1) _multiTouch = true;
                        },
                        onPointerUp: (_) =>
                            _pointerCount = math.max(0, _pointerCount - 1),
                        onPointerCancel: (_) =>
                            _pointerCount = math.max(0, _pointerCount - 1),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            CameraViewfinder(
                              controller: _session.cameraController,
                              filter: _filter,
                              intensity: _intensity,
                              showGrid: _gridEnabled,
                              enableFilter: true,
                              unmirrorFront: _session.videoMode,
                              digitalZoom: _session.previewDigitalZoom,
                              previewFit: _session.videoMode
                                  ? BoxFit.contain
                                  : BoxFit.cover,
                              isInitializing:
                                  _session.isInitializing ||
                                  _session.isSwitchingCamera ||
                                  _changingMode,
                              errorMessage:
                                  _actionError ?? _session.errorMessage,
                              onRetry: sensorBusy || _locked
                                  ? null
                                  : () => _cameraAction(_session.initialize),
                            ),
                            Positioned(
                              top: math.min(36, frameSize.height * .08),
                              right: 8,
                              child: IgnorePointer(
                                ignoring: !_zoomRulerVisible,
                                child: ExcludeSemantics(
                                  excluding: !_zoomRulerVisible,
                                  child: AnimatedOpacity(
                                    key: const Key('zoom-ruler-opacity'),
                                    opacity: _zoomRulerVisible ? 1 : 0,
                                    duration: const Duration(milliseconds: 300),
                                    child: Listener(
                                      onPointerDown: (_) {
                                        _rulerHeld = true;
                                        _rulerDragZoom = _session.currentZoom;
                                        _showZoomRuler();
                                      },
                                      onPointerUp: (_) => _releaseRuler(),
                                      onPointerCancel: (_) => _releaseRuler(),
                                      child: GestureDetector(
                                        key: const Key('zoom-ruler-drag'),
                                        behavior: HitTestBehavior.opaque,
                                        onTap: () {},
                                        onVerticalDragUpdate: _dragRuler,
                                        child: SizedBox(
                                          width: 66,
                                          height: math.min(
                                            170,
                                            math.max(
                                              80,
                                              frameSize.height * .35,
                                            ),
                                          ),
                                          child: ZoomRuler(
                                            zoom: _session.currentZoom,
                                            minZoom: _session.minZoom,
                                            maxZoom: _session.maxZoom,
                                            isDigital: _session.isDigitalZoom,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            if (_level.enabled)
                              Center(
                                child: IgnorePointer(
                                  child: CameraLevelIndicator(
                                    angleDegrees: _levelAngle(landscape),
                                    isAvailable: _level.isAvailable,
                                  ),
                                ),
                              ),
                            IgnorePointer(
                              child: AnimatedOpacity(
                                key: const Key('shutter-flash'),
                                opacity: _flashVisible ? .65 : 0,
                                duration: const Duration(milliseconds: 80),
                                child: const ColoredBox(color: Colors.white),
                              ),
                            ),
                            if (_focusPosition != null)
                              Positioned(
                                left: (_focusPosition!.dx - 28).clamp(
                                  0,
                                  math.max(0, frameSize.width - 56),
                                ),
                                top: (_focusPosition!.dy - 28).clamp(
                                  0,
                                  math.max(0, frameSize.height - 56),
                                ),
                                child: IgnorePointer(
                                  child: AnimatedOpacity(
                                    key: const Key('focus-indicator'),
                                    opacity: _focusVisible ? 1 : 0,
                                    duration: const Duration(milliseconds: 300),
                                    child: Container(
                                      width: 56,
                                      height: 56,
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color: Colors.yellow,
                                          width: 1.5,
                                        ),
                                        borderRadius: BorderRadius.circular(9),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            if (_countdown != null)
                              Center(
                                child: IgnorePointer(
                                  child: Semantics(
                                    liveRegion: true,
                                    label: '촬영까지 $_countdown초',
                                    child: Text(
                                      '$_countdown',
                                      key: const Key('capture-countdown'),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 80,
                                        fontWeight: FontWeight.w600,
                                        shadows: [
                                          Shadow(
                                            blurRadius: 12,
                                            color: Colors.black87,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: safe.top + 8,
                  left: 12,
                  right: 16,
                  child: Row(
                    children: [
                      IconButton(
                        key: const Key('camera-settings-button'),
                        tooltip: '카메라 설정',
                        onPressed: _locked ? null : _openSettings,
                        style: IconButton.styleFrom(
                          foregroundColor: Colors.white,
                          disabledForegroundColor: Colors.white30,
                          backgroundColor: Colors.black26,
                        ),
                        icon: const Icon(Icons.settings_outlined),
                      ),
                      if (!_session.videoMode) ...[
                        PopupMenuButton<int>(
                          key: const Key('capture-timer-button'),
                          tooltip: '촬영 타이머',
                          enabled: !_controlsLocked && !sensorBusy,
                          initialValue: _timerSeconds,
                          onSelected: (value) =>
                              setState(() => _timerSeconds = value),
                          color: const Color(0xff242424),
                          itemBuilder: (_) => [
                            for (final seconds in [0, 3, 5, 10])
                              PopupMenuItem(
                                value: seconds,
                                child: Text(
                                  seconds == 0 ? 'OFF' : '$seconds초',
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ),
                          ],
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 12,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.timer_outlined,
                                  color: _timerSeconds == 0
                                      ? Colors.white70
                                      : Colors.yellow,
                                  size: 22,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  _timerSeconds == 0
                                      ? 'OFF'
                                      : '${_timerSeconds}s',
                                  key: const Key('capture-timer-value'),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        IconButton(
                          key: const Key('camera-flash-button'),
                          tooltip: !_session.flashSupported
                              ? '플래시 미지원'
                              : (_session.flashEnabled ? '플래시 ON' : '플래시 OFF'),
                          onPressed: !_controlsLocked && _session.canToggleFlash
                              ? () => _cameraAction(
                                  () => _session.setFlashEnabled(
                                    !_session.flashEnabled,
                                  ),
                                )
                              : null,
                          style: IconButton.styleFrom(
                            foregroundColor: _session.flashEnabled
                                ? Colors.yellow
                                : Colors.white,
                            disabledForegroundColor: Colors.white30,
                            backgroundColor: Colors.black26,
                          ),
                          icon: Icon(
                            _session.flashEnabled
                                ? Icons.flash_on
                                : Icons.flash_off,
                          ),
                        ),
                      ],
                      const Spacer(),
                      if (_session.recoverablePhotoCount > 0)
                        IconButton(
                          key: const Key('retry-photo-save'),
                          tooltip:
                              '사진 저장 재시도 (${_session.recoverablePhotoCount})',
                          color: Colors.white,
                          icon: const Icon(Icons.refresh),
                          onPressed:
                              _session.pendingSaves >=
                                  CameraSession.maxPendingSaves
                              ? null
                              : () => _cameraAction(() async {
                                  await _session.retryFailedPhotos();
                                  if (mounted &&
                                      _session.recoverablePhotoCount > 0) {
                                    _showMessage(
                                      '사진 저장을 완료하지 못했어요. 권한과 저장 공간을 확인해 주세요.',
                                    );
                                  }
                                }),
                        ),
                      if (_session.isRecording)
                        _recordingBadge()
                      else if (_session.isVideoProcessing)
                        const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 13,
                              height: 13,
                              child: CircularProgressIndicator(
                                key: Key('video-processing-indicator'),
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            ),
                            SizedBox(width: 7),
                            Text(
                              '영상 처리 중',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        )
                      else if (_session.pendingSaves > 0)
                        Text(
                          '저장 중 ${_session.pendingSaves}',
                          key: const Key('pending-saves'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                    ],
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: size.height * .65),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ...[
                            Container(
                              margin: const EdgeInsets.symmetric(
                                horizontal: 24,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(2),
                              ),
                              child: Text(
                                _filter.name,
                                key: const Key('selected-filter-name'),
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.black,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                          ],
                          if (!_filter.isOriginal)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 28,
                              ),
                              child: SizedBox(
                                height: 30,
                                child: Row(
                                  children: [
                                    const Text(
                                      '강도',
                                      style: TextStyle(
                                        color: Colors.white70,
                                        fontSize: 11,
                                      ),
                                    ),
                                    Expanded(
                                      child: SliderTheme(
                                        data: SliderTheme.of(context).copyWith(
                                          trackHeight: 2,
                                          thumbShape:
                                              const RoundSliderThumbShape(
                                                enabledThumbRadius: 5,
                                              ),
                                          overlayShape:
                                              const RoundSliderOverlayShape(
                                                overlayRadius: 12,
                                              ),
                                        ),
                                        child: Slider(
                                          key: const Key(
                                            'filter-intensity-slider',
                                          ),
                                          value: _intensity,
                                          activeColor: Colors.white,
                                          inactiveColor: Colors.white30,
                                          label:
                                              '${(_intensity * 100).round()}%',
                                          onChanged: _controlsLocked
                                              ? null
                                              : (value) => setState(
                                                  () =>
                                                      _filterIntensities[_filter
                                                              .id] =
                                                          value,
                                                ),
                                        ),
                                      ),
                                    ),
                                    SizedBox(
                                      width: 37,
                                      child: Text(
                                        '${(_intensity * 100).round()}%',
                                        key: const Key(
                                          'filter-intensity-value',
                                        ),
                                        textAlign: TextAlign.right,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 11,
                                          fontFeatures: [
                                            FontFeature.tabularFigures(),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),

                          ColoredBox(
                            key: const Key('camera-controls-panel'),
                            color: Colors.black.withValues(alpha: .28),
                            child: Padding(
                              padding: EdgeInsets.fromLTRB(
                                0,
                                8,
                                0,
                                math.max(safe.bottom, 8),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  FilmFilterSelector(
                                    selected: _filter,
                                    intensity: _intensity,
                                    enabled: !_controlsLocked,
                                    onChanged: (filter) {
                                      unawaited(
                                        HapticFeedback.selectionClick()
                                            .catchError((Object _) {}),
                                      );
                                      setState(() => _filter = filter);
                                    },
                                  ),
                                  if (_session.videoMode)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Text(
                                        _session.isVideoProcessing
                                            ? '영상에 필름을 입히고 저장하고 있어요'
                                            : _filter.isOriginal
                                            ? '원본 동영상으로 녹화해요'
                                            : '${_filter.name} 필름으로 녹화해요',
                                        key: const Key('video-filter-notice'),
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      _modeButton(false, '사진'),
                                      _modeButton(true, '동영상'),
                                    ],
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 28,
                                    ),
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        _GalleryButton(
                                          photo: _latestPhoto,
                                          thumbnail:
                                              _latestPhoto?.id ==
                                                  _session
                                                      .latestPhotoThumbnailId
                                              ? _session.latestPhotoThumbnail
                                              : null,
                                          pending: _session.pendingSaves > 0,
                                          onThumbnail:
                                              _session.markThumbnailPresented,
                                          onPressed:
                                              sensorBusy ||
                                                  _galleryOpen ||
                                                  _locked
                                              ? null
                                              : _openGallery,
                                        ),
                                        _shutter(aspectRatio),
                                        SizedBox(
                                          width: 52,
                                          height: 52,
                                          child: IconButton(
                                            key: const Key(
                                              'switch-camera-button',
                                            ),
                                            tooltip: _session.isFrontCamera
                                                ? '후면 카메라로 전환'
                                                : '전면 카메라로 전환',
                                            onPressed:
                                                _session.canSwitchCamera &&
                                                    !_galleryOpen &&
                                                    !_controlsLocked
                                                ? () => _cameraAction(() {
                                                    _clearFocus();
                                                    return _session
                                                        .switchCamera();
                                                  })
                                                : null,
                                            style: IconButton.styleFrom(
                                              foregroundColor: Colors.white,
                                              disabledForegroundColor:
                                                  Colors.white30,
                                              backgroundColor: Colors.black26,
                                            ),
                                            icon: _session.isSwitchingCamera
                                                ? const SizedBox(
                                                    width: 22,
                                                    height: 22,
                                                    child:
                                                        CircularProgressIndicator(
                                                          strokeWidth: 2,
                                                          color: Colors.white,
                                                        ),
                                                  )
                                                : const Icon(
                                                    Icons.cameraswitch_outlined,
                                                    size: 28,
                                                  ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (_session.pendingSaves >=
                                      CameraSession.maxPendingSaves)
                                    const Padding(
                                      padding: EdgeInsets.only(top: 5),
                                      child: Text(
                                        '사진을 저장하고 있어요. 잠시만 기다려 주세요.',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          color: Colors.white70,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );

  Widget _modeButton(bool video, String label) => TextButton(
    key: ValueKey(video ? 'video-mode-button' : 'photo-mode-button'),
    onPressed:
        _controlsLocked || _session.isCapturing || _session.isSwitchingCamera
        ? null
        : () => _changeMode(video),
    style: TextButton.styleFrom(
      foregroundColor: _session.videoMode == video
          ? Colors.yellow
          : Colors.white70,
      disabledForegroundColor: Colors.white30,
      minimumSize: const Size(64, 32),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    child: Text(label, style: const TextStyle(fontSize: 12)),
  );

  Widget _recordingBadge() {
    final duration = _recordingWatch.elapsed;
    final minute = duration.inMinutes.toString().padLeft(2, '0');
    final second = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.circle, color: Colors.redAccent, size: 10),
            const SizedBox(width: 6),
            Text(
              '$minute:$second',
              key: const Key('recording-timer'),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _shutter(double ratio) {
    final video = _session.videoMode;
    final available = video
        ? !_recordingCommand &&
              !_session.isRecordingBusy &&
              (_session.isRecording || _session.canStartRecording)
        : _session.canCapture && !_locked;
    final enabled = available && !_galleryOpen;
    return AnimatedScale(
      scale: _session.isCapturing ? .93 : 1,
      duration: const Duration(milliseconds: 80),
      child: SizedBox(
        width: 72,
        height: 72,
        child: IconButton(
          key: const Key('capture-button'),
          iconSize: 52,
          tooltip: _countdown != null
              ? '촬영 타이머 취소'
              : video
              ? (_session.isRecording ? '동영상 녹화 정지' : '동영상 녹화 시작')
              : (_session.pendingSaves >= CameraSession.maxPendingSaves
                    ? '저장 대기 중'
                    : '사진 촬영'),
          onPressed: enabled
              ? () {
                  if (video) {
                    unawaited(_recordVideo());
                  } else {
                    _triggerCapture(ratio);
                  }
                }
              : null,
          style: IconButton.styleFrom(
            side: BorderSide(
              color: enabled ? Colors.white : Colors.white38,
              width: 3,
            ),
            shape: const CircleBorder(),
            padding: const EdgeInsets.all(5),
          ),
          icon: Center(
            child: AnimatedContainer(
              width: video && _session.isRecording ? 26 : 52,
              height: video && _session.isRecording ? 26 : 52,
              duration: const Duration(milliseconds: 120),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(
                  video && _session.isRecording ? 5 : 26,
                ),
                color: video
                    ? (enabled
                          ? Colors.redAccent
                          : Colors.redAccent.withValues(alpha: .4))
                    : (enabled ? Colors.white : Colors.white38),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GalleryButton extends StatelessWidget {
  const _GalleryButton({
    required this.photo,
    required this.onPressed,
    this.thumbnail,
    this.pending = false,
    this.onThumbnail,
  });
  final SavedPhoto? photo;
  final VoidCallback? onPressed;
  final Uint8List? thumbnail;
  final bool pending;
  final ValueChanged<String>? onThumbnail;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 52,
    height: 52,
    child: IconButton(
      key: const Key('gallery-button'),
      tooltip: '갤러리',
      onPressed: onPressed,
      style: IconButton.styleFrom(
        foregroundColor: Colors.white,
        disabledForegroundColor: Colors.white30,
        side: const BorderSide(color: Colors.white54),
        padding: const EdgeInsets.all(3),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        backgroundColor: Colors.black26,
      ),
      icon: Stack(
        alignment: Alignment.center,
        children: [
          photo == null
              ? const Icon(Icons.photo_library_outlined)
              : photo!.isVideo
              ? const Icon(Icons.play_circle_outline)
              : ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: thumbnail != null
                      ? Image.memory(
                          thumbnail!,
                          width: 44,
                          height: 44,
                          fit: BoxFit.cover,
                          excludeFromSemantics: true,
                          frameBuilder: (context, child, frame, sync) {
                            if (frame != null) {
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                final id = photo?.id;
                                if (id != null) onThumbnail?.call(id);
                              });
                            }
                            return child;
                          },
                        )
                      : Image.file(
                          File(photo!.path),
                          width: 44,
                          height: 44,
                          fit: BoxFit.cover,
                          cacheWidth: 120,
                          frameBuilder: (context, child, frame, sync) {
                            if (frame != null) {
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                final id = photo?.id;
                                if (id != null) onThumbnail?.call(id);
                              });
                            }
                            return child;
                          },
                          excludeFromSemantics: true,
                          errorBuilder: (_, _, _) =>
                              const Icon(Icons.photo_library_outlined),
                        ),
                ),
          if (pending)
            Positioned(
              right: 0,
              top: 0,
              child: Semantics(
                label: '사진 저장 중',
                child: SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
