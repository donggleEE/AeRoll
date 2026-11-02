import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/camera_session.dart';
import '../models/film_filter.dart';
import '../models/saved_photo.dart';
import '../widgets/camera_viewfinder.dart';
import '../widgets/film_filter_selector.dart';
import 'gallery_screen.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key, this.session});
  final CameraSession? session;

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  late final CameraSession _session;
  FilmFilter _filter = filmFilters.last;
  final double _intensity = 1;
  bool _galleryOpen = false;
  bool _flashVisible = false;
  Timer? _flashTimer;
  String? _actionError;
  SavedPhoto? _latestPhoto;

  @override
  void initState() {
    super.initState();
    _session = widget.session ?? CameraSession();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_cameraAction(_session.initialize));
    unawaited(_refreshLatestPhoto());
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
      // 갤러리 진입 시 저장소 오류와 재시도 방법을 안내한다.
    }
  }

  Future<void> _cameraAction(Future<void> Function() action) async {
    try {
      await action();
      if (mounted) setState(() => _actionError = null);
    } catch (error) {
      if (mounted) setState(() => _actionError = error.toString());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_galleryOpen) unawaited(_cameraAction(_session.resume));
    } else {
      unawaited(_cameraAction(_session.suspend));
    }
  }

  Future<void> _capture(double frameAspectRatio) async {
    if (!_session.canCapture || _galleryOpen) return;
    unawaited(HapticFeedback.lightImpact().catchError((Object _) {}));
    _flashTimer?.cancel();
    setState(() => _flashVisible = true);
    _flashTimer = Timer(const Duration(milliseconds: 90), () {
      if (mounted) setState(() => _flashVisible = false);
    });
    try {
      // 이 Future는 실제 저장 완료까지 기다리지만 UI 잠금에는 사용하지 않는다.
      // 다음 촬영 가능 여부는 센서 취득 및 큐 용량을 아는 canCapture가 결정한다.
      final photo = await _session.capture(
        filter: _filter,
        intensity: _intensity,
        frameAspectRatio: frameAspectRatio,
      );
      if (!mounted) return;
      setState(() => _latestPhoto = photo);
      _showMessage('사진을 기기 앨범에 저장했어요');
    } catch (error) {
      if (mounted) _showMessage('사진을 저장하지 못했어요. $error');
    }
  }

  void _showMessage(String message) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _openGallery() async {
    if (_galleryOpen || _session.isCapturing || _session.isSwitchingCamera) {
      return;
    }
    setState(() => _galleryOpen = true);
    await _cameraAction(_session.suspend);
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => GalleryScreen(repository: _session.repository),
      ),
    );
    if (!mounted) return;
    setState(() => _galleryOpen = false);
    unawaited(_refreshLatestPhoto());
    final state = WidgetsBinding.instance.lifecycleState;
    if (state == null || state == AppLifecycleState.resumed) {
      await _cameraAction(_session.resume);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _flashTimer?.cancel();
    if (widget.session == null) _session.dispose();
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
        animation: _session,
        builder: (context, _) => LayoutBuilder(
          builder: (context, constraints) {
            // 기기 실행 첫 프레임에 크기가 0일 수 있어 비율 계산을 늦춘다.
            if (!constraints.hasBoundedWidth ||
                !constraints.hasBoundedHeight ||
                constraints.maxWidth <= 0 ||
                constraints.maxHeight <= 0) {
              return const SizedBox.shrink();
            }
            final aspectRatio = constraints.maxWidth / constraints.maxHeight;
            final safe = MediaQuery.paddingOf(context);
            final sensorBusy =
                _session.isCapturing || _session.isSwitchingCamera;
            return Stack(
              fit: StackFit.expand,
              children: [
                CameraViewfinder(
                  controller: _session.cameraController,
                  filter: _filter,
                  intensity: _intensity,
                  isInitializing:
                      _session.isInitializing || _session.isSwitchingCamera,
                  errorMessage: _actionError ?? _session.errorMessage,
                  onRetry: sensorBusy
                      ? null
                      : () => _cameraAction(_session.initialize),
                ),
                IgnorePointer(
                  child: AnimatedOpacity(
                    key: const Key('shutter-flash'),
                    opacity: _flashVisible ? .65 : 0,
                    duration: const Duration(milliseconds: 80),
                    child: const ColoredBox(color: Colors.white),
                  ),
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.black54, Colors.transparent],
                      ),
                    ),
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(22, safe.top + 16, 22, 28),
                      child: Row(
                        children: [
                          const Spacer(),
                          if (_session.pendingSaves > 0)
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
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: constraints.maxHeight * .65,
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            margin: const EdgeInsets.symmetric(horizontal: 24),
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
                          ColoredBox(
                            key: const Key('camera-controls-panel'),
                            color: Colors.black.withValues(alpha: .28),
                            child: Padding(
                              padding: EdgeInsets.fromLTRB(
                                0,
                                10,
                                0,
                                math.max(safe.bottom, 10),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  FilmFilterSelector(
                                    selected: _filter,
                                    intensity: _intensity,
                                    onChanged: (filter) {
                                      unawaited(
                                        HapticFeedback.selectionClick()
                                            .catchError((Object _) {}),
                                      );
                                      setState(() => _filter = filter);
                                    },
                                  ),
                                  const SizedBox(height: 8),
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
                                          onPressed: sensorBusy || _galleryOpen
                                              ? null
                                              : _openGallery,
                                        ),
                                        AnimatedScale(
                                          scale: _session.isCapturing ? .93 : 1,
                                          duration: const Duration(
                                            milliseconds: 80,
                                          ),
                                          child: SizedBox(
                                            width: 72,
                                            height: 72,
                                            child: IconButton(
                                              key: const Key('capture-button'),
                                              iconSize: 52,
                                              tooltip:
                                                  _session.pendingSaves >=
                                                      CameraSession
                                                          .maxPendingSaves
                                                  ? '저장 대기 중'
                                                  : '사진 촬영',
                                              onPressed:
                                                  _session.canCapture &&
                                                      !_galleryOpen
                                                  ? () => unawaited(
                                                      _capture(aspectRatio),
                                                    )
                                                  : null,
                                              style: IconButton.styleFrom(
                                                side: BorderSide(
                                                  color: _session.canCapture
                                                      ? Colors.white
                                                      : Colors.white38,
                                                  width: 3,
                                                ),
                                                shape: const CircleBorder(),
                                                padding: const EdgeInsets.all(
                                                  5,
                                                ),
                                              ),
                                              icon: AnimatedContainer(
                                                duration: const Duration(
                                                  milliseconds: 90,
                                                ),
                                                decoration: BoxDecoration(
                                                  shape: BoxShape.circle,
                                                  color: _session.canCapture
                                                      ? Colors.white
                                                      : Colors.white38,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
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
                                                    !_galleryOpen
                                                ? () => _cameraAction(
                                                    _session.switchCamera,
                                                  )
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
}

class _GalleryButton extends StatelessWidget {
  const _GalleryButton({required this.photo, required this.onPressed});
  final SavedPhoto? photo;
  final VoidCallback? onPressed;

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
      icon: photo == null
          ? const Icon(Icons.photo_library_outlined)
          : ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: Image.file(
                File(photo!.path),
                width: 44,
                height: 44,
                fit: BoxFit.cover,
                cacheWidth: 120,
                excludeFromSemantics: true,
                errorBuilder: (_, _, _) =>
                    const Icon(Icons.photo_library_outlined),
              ),
            ),
    ),
  );
}
