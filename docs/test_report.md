# 카메라·필터·갤러리 검증 결과

## 최신 검증: 2026년 11월 4일 촬영 후처리 지연 최적화

- 변경 Dart 포맷 완료, `flutter analyze --no-pub` 문제 없음(2.1초), `flutter test --no-pub --reporter compact` **101건 모두 통과**(약 7초).
- Android Studio JBR의 `flutter build apk --debug --no-pub` 성공(14.1초), `build/app/outputs/flutter-apk/app-debug.apk` 187,622,627바이트.
- 수정 전후 JPEG/PNG 바이트 일치 72개 조합, 썸네일이 최종 파일을 바꾸지 않음, 원본/0%·필터 색/알파·EXIF·크롭·줌·기존 UI 회귀를 확인했다.
- 실제 worker의 CPU 처리 중 주 isolate 타이머 응답, 실패한 원본·설정 보존, 재시작 발견, JPEG 재처리 없는 앨범 재시도, 완료 ID의 중복 호출 방지, 보관 디렉터리 실패 후 재시도, 3장 큐·종료 후 저장을 검사했다.
- 별도 `flutter test --no-pub tool/photo_session_benchmark_test.dart`도 1건 통과했다. 12MP 세 장이 실제 worker와 Windows 파일 저장을 거쳐 완료됐고, 카메라 해제 뒤에도 큐가 완료됐다. 센서와 앨범은 파일 복사 대역이며 실제 기기 측정이 아니다.
- 동일 Windows/JIT/12MP/JPEG95 입력의 중앙값: cold 50% 1배 전체 후처리 1,567→1,080ms, 필터 428→61ms, 3배 전체 후처리 1,958→1,425ms. 원본은 1,024→977ms였다. 프로세스 최대 RSS는 1배 묶음에서 약 463→375MiB였으며 모바일 메모리를 의미하지 않는다.
- 실기기 캡처·다음 촬영 가능 시각·앨범 저장·미리보기 FPS·발열·장시간 연속 촬영과 iOS는 미검증이다. 이전 기능의 에뮬레이터 확인을 이번 기능 검증으로 재사용하지 않았다.

자세한 단계별 표, 계측 필드, 원본 보존 범위와 재현 명령은 [촬영 성능 보고서](photo_performance.md)를 참고한다.

## 이전 검증: 2026년 11월 4일 촬영 조작·필터 강도 확장

### 구현과 자동 검증 범위

| 기능 | 구현 | 검증 |
|---|---|---|
| 터치 초점 | 크롭·확대·추가 반전과 표시/플랫폼 방향 차이를 보정한 좌표 전달, 표시 후 페이드 | 좌표 6건, 실제 두 포인터 핀치·버튼·슬라이더와 초점 충돌 방지, 미지원·실패 복구 |
| 촬영 타이머 | OFF·3·5·10초, 기본 OFF, 미리보기 카운트다운과 재셔터 취소 | 정시 한 번 촬영, 중복 방지, 백그라운드·갤러리 이동·종료 취소 |
| 플래시 | 기본 OFF, 촬영 순간 발광하는 `FlashMode.always`, native 카메라 ID별 지원 조회 | ON/OFF·미지원 비활성화·오류·렌즈 전환·복귀, torch 사용 없음 |
| 눈금 드래그 | 현재 배율을 기준으로 세로 이동 거리의 연속 배율 조절, 상하한, 손가락 유지 중 숨김 방지 | 첫 입력 배율 유지, 위로 확대·아래로 축소, 최소·최대 제한, 놓은 뒤 2초 숨김, 기존 핀치 |
| 촬영 완료 안내 | 사진 저장 성공 하단 스낵바 제거 | 저장·갤러리 갱신과 실패 안내 회귀 유지 |
| 필터 강도 | 필터 목록 근처의 0~100% 슬라이더, 필터별 마지막 값 기억, 원본에서 숨김 | 0·50·100%의 미리보기 인자·사진 저장 일치, cold 클리핑 순서와 기존 100% 보존 |

방향 보정은 로컬 camera 플러그인 구현을 확인했다. Android는 Display 기반 방향·전면 보정을 수행하고 iOS는 기기 방향 변환을 수행하므로, 앱이 적용하는 추가 반전과 고정 미리보기 방향 차이를 별도로 처리한다. 기기 자체의 실제 초점 위치 검증을 대신하지 않는다.

강도는 `원본 × (1-강도) + clamp(완전 필터) × 강도`이며 최종 8비트 정수화 전에 double로 계산한다. CPU 미리보기 처리와 isolate PNG 저장은 동일 입력·크기에서 정확히 일치했다. Windows 렌더링의 일반·불투명 경로는 0·1·50·90·99·100%에서 채널 오차 1 이내, 반투명 결과를 배경에 추가 합성한 경로는 두 단계 반올림을 포함해 2 이내였다. 알파 0·64·128·255도 유지했다.

Impeller는 단일 패스 `film_filter.frag`를 사용한다. 지원하지 않는 렌더러는 불투명 카메라 Texture 또는 일반 래스터용 호환 혼합 경로를 사용한다. 셰이더 에셋 컴파일·로드와 파라미터는 검사했으며, 실제 Impeller 픽셀·카메라 Texture의 기기별 성능 검증은 수행하지 않았다. 영상에도 선택 강도를 전달하고 0%·무줌은 재출력을 생략한다.

### 최종 실행 결과

- 변경 Dart 파일에 `dart format` 실행.
- `flutter pub get --offline` 성공. 신규 제품 패키지는 추가하지 않았다.
- `flutter analyze --no-pub`: 문제 없음, 최종 43.6초.
- `flutter test --no-pub --reporter compact`: 최종 **93건 모두 통과**, 약 9초. 기존 촬영·저장·갤러리·권한·수명주기·영상 회귀와 기준 JPG 비교를 포함한다.
- `flutter build apk --debug --no-pub`: Android Studio JBR로 최종 성공, 28.7초. `build/app/outputs/flutter-apk/app-debug.apk`, 165,238,440바이트. 마지막 좌표 보정을 포함한 APK다.
- `git diff --check`: 공백 오류 없음. 기존 저장소의 LF/CRLF 안내는 있었으나 검사 실패는 없었다.
- 화면 배치 참고 산출물은 `build/camera_controls_ui.png`다. Windows 테스트 폰트로 일부 글자·아이콘은 네모로 표시되므로 실제 기기 화면 캡처와 구분한다. 320×568 두 배 글자 크기 레이아웃 회귀도 통과했다.
- 12MP cold 50% Windows JIT 단일 처리 측정: 2007ms, 주 isolate 10ms 타이머 151회 응답. `build/filter_strength_benchmark.dart`에 실행 코드를 남겼다. 주 isolate에서 디코딩·픽셀 처리를 하지 않지만 실제 모바일 프레임 속도·발열·메모리 성능을 보장하는 수치는 아니다.

### 남은 실기기 검증

Android 연결 기기가 없어 실제 초점 위치와 모터 동작, 캡처 순간 플래시 발광, 모바일 GPU의 강도·색 정확도와 반응 속도, 새 기능을 사용한 기기 앨범 저장·영상 출력·음성 품질은 확인하지 못했다. Windows에서 iOS 빌드·실행도 수행하지 않았다. sRGB 이외의 일반 ICC 색공간 변환, JPEG 손실 압축과 플랫폼 영상 작업색공간 차이에 대한 기존 제한도 유지한다. 아래 기준 JPG 수치는 100% 효과의 비교이며 모든 기기의 픽셀 완전 일치를 의미하지 않는다.

## 2026년 11월 4일 제공 JPG 기준 비교

사용자가 `test/fixtures/filter_reference/`에 제공한 `base.jpg`, `warm_reference.jpg`, `cold_reference.jpg`를 사용했다. 세 이미지 모두 방향 보정 후 700×840이다. 원본에서 각각 필터를 한 번 적용하고 크롭·리사이즈·정렬·자동 보정 없이 PNG로 출력했다. 필터 상수는 변경하지 않았다.

| 필터 | MAE R | MAE G | MAE B | 평균 부호 오차 R | 평균 부호 오차 G | 평균 부호 오차 B | 전체 RMSE |
|---|---:|---:|---:|---:|---:|---:|---:|
| warm | 1.88336 | 1.64916 | 1.67201 | -0.20673 | 0.01063 | 0.02744 | 2.60048 |
| cold | 1.51196 | 1.31059 | 1.71315 | 0.23015 | 0.27300 | 0.21043 | 2.47645 |

채널 단위는 0~255이며 부호는 계산 출력에서 기준 JPG를 뺀 값이다. sRGB를 기준으로 계산하고 기존 코드와 마찬가지로 일반 ICC 변환은 수행하지 않는다. 손실 JPG와 디코더 차이를 포함한 비교이며 피그마와 픽셀 단위 완전 일치의 증거는 아니다.

- 실행: `dart run tool/compare_filter_references.dart test/fixtures/filter_reference/base.jpg test/fixtures/filter_reference/warm_reference.jpg test/fixtures/filter_reference/cold_reference.jpg build/filter_reference_comparison`.
- 출력: `build/filter_reference_comparison/warm_output.png`, `cold_output.png`, `comparison.json`.
- `test/filter_reference_test.dart`에서 오차 집계 수식, 크기 유지와 기준 이미지 회귀를 검증했다. 최초 관련 테스트 2건이 통과했다.

## 이전 검증: 2026년 11월 4일 고정 RGB 필터 교체

기존 PNG 필터 검증과 아래 RGB 변환의 최초 검증은 별개다. 당시 기준 이미지가 없던 제한은 위의 후속 비교로 보완했다.

- `dart format`: 변경한 Dart 파일에 실행했다.
- `flutter pub get --offline`: 로컬 캐시로 성공했다. 신규 제품 의존성은 추가하지 않았다.
- `flutter analyze --no-pub`: 최종 문제 없음, 5.1초.
- `flutter test --no-pub --reporter compact`: 최종 70건 모두 통과, 약 8초. 전체 검사에서 발견된 이전 PNG 존재를 전제한 줌 테스트는 새 카메라 확대·고정 RGB 행렬 계약으로 갱신하고 재실행했다.
- `flutter build apk --debug --no-pub`: Android Studio JBR로 성공, 38.6초. 출력은 `build/app/outputs/flutter-apk/app-debug.apk`이며 165,207,161바이트다.
- 수학 테스트: 검정·흰색·128 회색·빨강·초록·파랑과 모든 8비트 채널 값에서 순차 double 기준식과 최적 선형식의 최종 결과를 비교했다. cold 음수 클리핑, 원본 무변환과 알파 보존도 확인했다.
- 사진 경로: EXIF 방향·기존 중앙 크롭·반전·디지털 줌 순서를 확인했다. 같은 입력·크기의 CPU 미리보기와 영구 isolate PNG 저장 출력이 픽셀 단위로 일치했다. JPEG 저장은 품질 95의 손실 압축 오차를 따로 허용해 필터 누락·중복 적용을 검사했다.
- Flutter 래스터 검증: 불투명 기본 RGB 6종은 공통 행렬과 CPU 순차식이 일치했다. warm→cold→cold→원본→warm 전환은 누적되지 않았다. 알파 0·64·128·255를 보존했고 반투명 premultiplied 출력 반올림 차이는 채널별 1 이내였다.
- 영상 서비스 6건은 공통 계수 전달, 줌 타임라인, 원본 재출력 생략 조건, 빈 출력·출력 오류·복구 명세 보존을 확인했다. Android 네이티브 `:app:compileDebugKotlin --offline`도 Android Studio JBR로 성공했다.
- 성능 참고: Windows Dart JIT에서 합성 4000×3000 JPEG 한 장을 warm으로 디코딩·픽셀 처리·JPEG 인코딩하는 영구 isolate 작업은 2048ms였다. 해당 구간 main isolate의 10ms heartbeat는 180회 실행되었다. 단일 측정이며 실제 휴대폰의 처리 시간·발열·메모리 보장이 아니다. 벤치 실행 파일은 `build/filter_benchmark.dart`다.

### 기준 이미지와 지원 제한

- `base.jpg`, `warm_reference.jpg`, `cold_reference.jpg`가 제공되지 않아 기준 JPG 비교는 미수행이다. MAE·평균 부호 오차·RMSE 수치를 새로 측정하지 않았다. 피그마와 픽셀 단위 완전 일치를 주장하지 않는다.
- 사진 기준 색공간은 sRGB다. 기존 `image` 디코더는 ICC 정보를 보존하지만 일반 ICC→sRGB 색관리 변환을 수행하지 않는다. 다른 프로필·광색역 입력의 같은 색 결과를 보장하지 않는다.
- 실제 앱 사진은 기존 JPEG 출력이므로 정확 비교용 PNG와 달리 추가 손실 압축이 있다. 투명 이미지의 알파 보존 검증은 CPU 처리·PNG 및 Flutter 렌더링 경로에 해당하며 JPEG는 투명도를 지원하지 않는다.
- Windows Flutter 테스트 렌더러 검증과 Android/iOS 실제 카메라 Texture·GPU 검증은 다르다. 이번 작업에서는 연결된 Android 기기가 없었고 실제 촬영·기기 앨범 저장·새 영상 파일 픽셀 검증은 수행하지 않았다. iOS는 Windows 환경에서 빌드·실행하지 못했다.
- Android Media3 1.9.2의 SDR 기본 작업공간은 SMPTE170m 전기 RGB다. 영상에는 같은 수학적 계수를 적용하지만 sRGB 사진과의 색관리·GPU 정밀도·영상 인코더 차이를 포함한 픽셀 동일성을 보장하지 않는다. iOS는 sRGB Core Image 행렬과 최종 인코더를 사용한다. HDR 영상 필터 출력은 명시적으로 거부한다. [Media3 작업공간 구현](https://raw.githubusercontent.com/androidx/media/1.9.2/libraries/effect/src/main/java/androidx/media3/effect/DefaultVideoFrameProcessor.java), [Apple 색상 행렬 계약](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Reference/CoreImageFilterReference/index.html)을 참고했다.

## 이전 검증: 2026년 11월 4일 확장 줌·영상 필터 출력

이 절이 현재 코드의 검증 결과다. 아래 47건 및 이전 에뮬레이터 기록은 과거 이력이며 이번 영상 필터 출력의 완료 근거로 대신하지 않는다.

- `flutter analyze --no-pub`: 문제 없음(1.7초).
- `flutter test --no-pub`: **64개 모두 통과**(약 7초).
- `dart format test`: 완료.
- `flutter build apk --debug --no-pub`: Android 알파 결함 수정 후 **최종 일반 APK 빌드 성공**(19.4초). 산출물은 `build/app/outputs/flutter-apk/app-debug.apk`다. 최초 통합 빌드 성공(39.9초)과 구분한다.
- 실제 Android 영상 인코딩·필터 픽셀·줌·오디오·방향 비교는 메인이 별도로 담당한다. 아래 채널 대역 테스트는 실제 MP4 출력 성공을 뜻하지 않는다.

### 새 검증 구성과 기존 회귀 갱신

| 범위 | 수 | 확인한 내용 |
|---|---:|---|
| 기존 사진·설정·센서·녹화·저장·화면 회귀 | 47 | 기존 동작을 보존하고 논리 줌 상한 100배, 영상 필터 선택과 새 호출 인자에 맞춰 대역 및 기대값 갱신 |
| `test/digital_zoom_test.dart` | 7 | 즉시 논리 배율·네이티브와 소프트웨어 분리, 지원 기기만 0.6배·기본 1배, 사진 배율 고정, 실제 사진 픽셀 자르기·고정 오버레이·작은 이미지 100배, 영구 처리기 배율 전달, 녹화 기준 줌·필터·타임라인 고정과 출력 후 저장, 출력 실패 시 원본 대체 저장 금지 |
| `test/video_processor_test.dart` | 7 | 출력 채널 인자와 PNG 알파, 실제 출력 파일 존재 검사, 원본·줌 없음만 출력 생략, 실패 작업 보존과 다음 성공 정리 분리, 타임라인 입력 검증, 에셋 읽기 및 잘못된 PNG 오류의 작업 명세 보존 |
| `test/zoom_ruler_ui_test.dart` | 3 | 핀치 중 표시·종료 2초 경계·300ms 페이드, 새 제스처의 숨김 예약 취소 및 종료 정리, 확대는 카메라에만 적용하고 필름은 고정 |

영상 서비스 검사는 주입한 채널 핸들러와 임시 파일을 사용한다. 합성 알파 검사는 원본 알파 128에 강도 0.5를 적용한 전달 PNG의 알파가 64임을 확인한다. 사진 합성은 알려진 색상 영역으로 디지털 확대 후 중앙 픽셀이 실제 출력에 반영되고 오버레이 영역은 확대되지 않음을 확인한다. 영상 키프레임은 네이티브 기준 줌을 고정한 상태에서 추가 디지털 배율만 기록하는지 검사했다.

### 발견 및 수정

- 기존 47건의 첫 새 실행은 46건 통과, 1건 실패였다. 실패는 원본 영상에서 필터를 숨기던 이전 정책의 테스트 기대값이며, 새 요청에 따라 영상 모드 필터 표시·선택·녹화 중 고정으로 갱신했다.
- 실제 결함으로 영상 필터 에셋 읽기 실패 때 복구 원본은 보존되지만 작업 명세가 생성되지 않는 문제를 확인했다. backend가 에셋 처리 전에 작업 명세를 기록하고 준비 완료 후 원자적으로 갱신하도록 수정했다. 에셋 읽기 실패와 잘못된 PNG 알파 변환 실패 모두 최종 테스트에서 명세 보존을 확인했다.
- 메인의 실제 Android 출력 픽셀 비교에서 별도의 네이티브 알파 결함을 발견했다. Canvas의 premultiplied RGB에 Media3 오버레이 셰이더가 알파를 다시 곱해 필름이 어두워졌고, 수정 전 출력과 Pillow 기준의 평균 픽셀 오차는 255 기준 27.64였다. video_platform 담당자가 straight-alpha RGBA 복원으로 수정했다. Kotlin 컴파일 성공 후 아래 실제 출력 비교에서 오차 감소와 정합성을 확인했다.
- 새 테스트 작성 과정의 문법·생성자 오류는 수정한 뒤 전체 분석과 테스트를 재실행했다. 운영 코드 결함과 구분한다.

### 메인의 실제 Android 네이티브 파일 검증

- 메인은 회전 메타데이터가 90도인 테스트 영상을 실제 Android 네이티브 출력기에 전달하고 출력 240×320으로 표시 방향이 유지되는 것을 확인했다.
- 알파 수정 후 1·2·4·100배 구도와 PNG 합성 결과를 Pillow 기준 이미지와 비교했다. 실제 영상 프레임의 평균 픽셀 오차는 다음과 같았다(채널 범위 0~255).

| 디지털 확대 | 수정 후 평균 픽셀 오차 |
|---|---:|
| 1배 | 3.834 |
| 2배 | 2.833 |
| 4배 | 1.430 |
| 100배 | 1.290 |

- 수정 전 평균 오차 27.64와 비교해 네이티브 알파 결함이 해결되었고, 확대된 카메라 영상 뒤에 고정 필터를 합성하는 결과가 기준과 일치함을 확인했다. 이 값은 해당 테스트 영상의 검증 결과이며 모든 기기의 화질 보장은 아니다.
- 출력 오디오 길이 3.019초, 주파수 약 440.27Hz, RMS 2884.55의 테스트 신호 보존도 확인했다. 이 값은 실제 목소리 녹음 품질이나 물리 기기 음질 보장이 아니다.
- 검증 산출물은 `build/qa_filtered_v2.mp4`와 `build/`의 원본 테스트 영상·기준 PNG 파일이다. 메인이 실제 파일을 분석한 결과이며 채널 대역 테스트와 구분한다.
- 순수 네이티브 알파 수정이므로 위 64개 Dart 테스트 결과는 유지한다. 수정 후 일반 Android APK도 최종 빌드에 성공했다(19.4초).

### 메인의 최종 실제 앱 녹화·저장·재생 및 눈금 확인

- 실제 앱에서 콜드 필터를 선택해 37.432초 녹화하고 Media3 합성 완료 후 MediaStore ID 36에 1280×720, 길이 37,432ms 영상이 저장되는 것을 확인했다. 최종 세션은 `isVideoProcessing=false`, `errorMessage=null`이었다.
- 앱 갤러리에서 해당 영상을 열어 실제 영상 상세의 콜드 영상 라벨과 필터 색상, 세로 표시 방향을 메인이 직접 확인했다. 화면은 `build/filtered_video_gallery.png`, `build/filtered_video_playback.png`다. 이는 위 테스트 영상의 수치 비교와 별개의 실제 앱 파이프라인 확인이다.
- 실제 앱의 100배 눈금 표시를 `build/zoom_ruler_100_visible.png`에서 확인했다. 핀치를 유지하는 동안 표시되고 종료 후 약 1.9초에는 표시, 약 2.4초에는 숨김 상태였다. VM 관측 순서는 `[true, true, false]`로 2초 후 페이드 숨김 정책과 일치했다.
- 최소 0.6배는 기기가 해당 광각 배율을 지원할 때만 제공한다. 100배는 디지털 확대를 포함하며 물리 기기의 광학 성능이나 고배율 화질을 보장하지 않는다.
- 물리 기기의 실제 음성 녹음 품질과 장시간 처리 성능, iOS 빌드 및 실제 출력은 여전히 미검증이다. 이번 최종 확인 뒤 새 테스트나 빌드를 추가하지 않았다.

### 테스트 변경 파일과 실행 명령

- 생성: `test/digital_zoom_test.dart`, `test/video_processor_test.dart`, `test/zoom_ruler_ui_test.dart`, `test/support/fake_video_processor.dart`.
- 수정: `test/support/fake_photo_processor.dart`, `test/ui_checks.dart`, `test/camera_zoom_video_test.dart`, `test/camera_settings_video_ui_test.dart`, 이 보고서.
- 실행: `dart format test`, 관련 개별 `flutter test ... --no-pub`, 최종 `flutter analyze --no-pub`, `flutter test --no-pub`, `flutter build apk --debug --no-pub`.
- tester는 운영 코드를 수정하지 않았고 복구 명세 결함은 backend 담당자가 수정했다. Git 커밋·푸시는 수행하지 않았다.

### 이번 변경의 제한

- 최대 100배는 디지털 확대가 포함되며 광학 성능이나 화질을 보장하지 않는다. 0.6배 실제 렌즈 지원은 기기에 따라 다르다.
- 네이티브 출력의 실제 오디오·방향·시간·필터 픽셀과 확대 구도는 별도 파일 검증 결과를 추가해야 한다.
- Windows에서 iOS 출력 코드를 빌드하거나 실제 AVFoundation 결과를 확인하지 못했다.
- 물리 기기의 출력 처리 시간, 발열·메모리, 장시간 녹화 및 저해상도·고배율 화질은 별도 실기기 확인이 필요하다.

## 이전 검증: 2026년 11월 3일 줌·설정·수평계·동영상 확장

이 절이 현재 변경의 검증 결과다. 아래 25건 검증과 에뮬레이터 기록은 이전 기능의 이력으로 유지한다.

- `dart format test`: 완료.
- `flutter analyze --no-pub`: 문제 없음(3.8초).
- `flutter test --no-pub`: **47개 모두 통과**(약 4초).
- `flutter build apk --debug --no-pub`: **성공**(27.9초), 산출물 `build/app/outputs/flutter-apk/app-debug.apk`.
- 실제 에뮬레이터 앱 실행과 영상·센서 조작 확인은 메인 에이전트가 담당한다. 아래 대역 검증과 구분해 결과를 추가한다.

### 새 자동 검증 구성

| 범위 | 수 | 확인 내용 |
|---|---:|---|
| 기존 사진·저장 큐·합성·캐시·화면 회귀 | 25 | 기존 기능을 유지하며 기본 사진 영역 기대값은 새 요구인 9:16으로 갱신 |
| `test/camera_zoom_video_test.dart` | 7 | 줌 범위·클램프·최신값 합치기·오류, 렌즈 전환 시 배율 초기화, 사진/영상별 오디오 생성 옵션, 중복 녹화·정지 제한, 앱 중지·종료 자동 저장, 마이크 거부 및 저장 실패 복구, 네이티브 정지 실패 후 복귀 |
| `test/level_controller_test.dart` | 3 | 센서 구독 토글·중지·복귀·해제, 평평한 자세·센서 오류·오래된 값 무효화, ±2도 노란색 경계 및 무효 중립 표시 |
| `test/video_repository_test.dart` | 3 | 영상 앱 사본과 앨범 쓰기 함수, 혼합 재조회, 앨범 실패 시 복구 사본과 명시적 오류, 예전 사진 JSON 및 빈 영상 거부 |
| `test/camera_settings_video_ui_test.dart` | 9 | 가로 수평계 방향 보정, 실제 두 포인터 핀치와 한 손가락 무시, 설정 격자·수평계 반영, 세 가지 사진 비율의 검정 여백과 촬영 인자, 원본 영상 안내·타이머·잠금·정지, 혼합 갤러리 및 재생 오류·재시도 |

사진 모드 진입은 `enableAudio=false`, 영상 모드 진입은 `true`, 사진 복귀는 다시 `false`로 컨트롤러가 생성되는지 테스트 대역으로 확인했다. 실제 운영체제의 마이크 권한 대화상자는 이 자동 검사만으로 확인한 것이 아니다. 센서와 네이티브 녹화·앨범 쓰기도 대역을 사용하므로 실제 오디오 품질·센서 정확도·미디어 재생 성공의 근거로 사용하지 않는다.

### 이번 검증에서 발견하고 수정한 결함

1. 첫 회귀 실행 37건 중 35건이 통과했다. 새 화면에서 초기 너비 24픽셀일 때 조작부가 오른쪽으로 넘치는 실제 회귀를 발견했고 frontend가 좁은 초기 화면 방어를 복구했다. 다른 실패 1건은 요구가 전체 화면 비율에서 선택한 9:16으로 바뀌어 테스트 기대값을 갱신했다.
2. 확장 실행 45건 중 41건이 통과했다. 설정 시트의 장식 배경과 Material 계층 때문에 ListTile 배경·터치 효과가 가려지는 Flutter 단언 오류가 발생했다. frontend가 자체 투명 Material을 추가했고 설정·비율 관련 4건이 최종 실행에서 통과했다.
3. 비동기 녹화 종료 테스트는 임의의 한 이벤트 대기 대신 카메라 해제 완료 신호를 기다리도록 수정했다. 운영 코드 결함과 구분한다.

### 이번 작업의 테스트 파일과 명령

- 생성: `test/camera_zoom_video_test.dart`, `test/level_controller_test.dart`, `test/video_repository_test.dart`, `test/camera_settings_video_ui_test.dart`.
- 수정: `test/support/fake_camera.dart`, `test/ui_checks.dart`, 이 보고서.
- 실행: `dart format test`, 관련 개별 `flutter test ... --no-pub`, 최종 `flutter analyze --no-pub`, `flutter test --no-pub`, `flutter build apk --debug --no-pub`.
- tester는 운영 코드를 직접 수정하지 않았고 발견 결함을 담당자에게 전달해 수정 후 재검증했다.

### 메인 에이전트의 이번 Android 에뮬레이터 직접 검증

- 설정 버튼에서 격자 끄기·수평계 켜기·1:1 선택을 수행했다. 가속도 `0:9.8:0` 입력에서 노란 수평 표시를, `2:9.6:0`에서 약 12도의 흰 기울기선과 고정 기준선을 확인했다.
- 실제 MediaStore 사진 ID 35는 720×720, ID 37은 720×960, ID 38은 720×1280으로 생성되었다. 각각 1:1, 세로 4:3(3:4), 세로 16:9(9:16)의 선택 비율과 실제 저장 결과가 일치함을 확인했다.
- 사진 모드에서 `RECORD_AUDIO` 권한이 false인 것을 확인했고 영상 모드 진입 때만 마이크 권한 요청이 나타나 허용했다.
- 실제 네이티브 녹화 후 MediaStore 영상 항목 ID 36에 길이 30.564초, 1280×720 MP4가 저장되었다. MP4 박스를 직접 파싱해 영상 `avc1`과 오디오 `samr` 트랙 존재를 확인했다. 에뮬레이터가 소리 장치를 비활성화한 구성이라 실제 목소리와 녹음 음질은 검증하지 않았다.
- 앱 갤러리의 영상 항목, 실제 `video_player`의 초기 프레임과 재생 진행 및 일시정지 아이콘을 확인했다.
- 줌을 지원하는 전면 카메라에서 VM을 통해 `setZoom(12.931958)`을 호출하고 적용된 현재값을 읽은 뒤 1배로 복귀했다. 후면 가상 장면의 최대 줌은 1배였으며 해당 기기의 범위 제한을 따랐다. 실제 두 손가락 입력 흐름은 위젯 테스트로 검증했으며 이 VM 호출을 실제 멀티터치 검사로 표현하지 않는다.
- 메인이 직접 검토한 화면은 `build/camera_settings.png`, `build/camera_level_aligned.png`, `build/camera_level_tilted.png`, `build/video_recording.png`, `build/media_gallery.png`, `build/video_playing.png`다. 추가 비율 촬영과 최종 영상 재생까지 확인한 실행에서 Flutter 오류 등급 E 로그는 없었다.

### 이번 변경의 실기기 검증 제한

- 물리 기기의 실제 줌 범위, 멀티터치 반응과 녹화 성능, 센서 오차·흔들림·자세 변화.
- 실제 마이크 권한 및 녹음 품질, 녹화 파일의 원본 방향·비율, 기기별 재생 호환성.
- iOS 빌드·권한·센서·영상 저장과 재생.
- 동영상은 필터 없는 원본이며 사진 필터 합성 기능과 구분한다. 영상 앨범 저장이 실패하면 앱 복구 사본을 보존하지만 성공으로 표시하지 않는다.

## 이전 검증: 전체 화면·전후면 전환·촬영 응답성 개선

이 절은 `light.png`, `cold.png`, 예시 사진 썸네일과 유한 저장 큐가 반영된 최신 코드의 결과다. 아래 최초 구현의 16건 검증과 구분한다.

- `dart format test`: 완료.
- `flutter analyze --no-pub`: 최종 축소 UI 반영 후 문제 없음(4.6초).
- `flutter test --no-pub`: **25개 모두 통과**(테스트 실행 약 3초). 이 시간은 실제 촬영·저장 지연 측정값이 아니다.
- `flutter build apk --debug --no-pub`: **축소 UI가 반영된 최종 빌드 성공**(25.6초). 최신 산출물은 `build/app/outputs/flutter-apk/app-debug.apk`다. 첫 전체 화면 버전도 빌드에 성공했다(28.1초).
- 에뮬레이터 앱 실행·카메라 조작·시각 확인은 메인 에이전트가 별도로 수행했으며, 아래 결과는 메인의 직접 확인 보고를 반영했다. tester는 앱 실행을 중복 수행하지 않았다.

### 최신 자동 테스트 구성

| 파일 | 수 | 범위 |
|---|---:|---|
| `test/photo_compositor_test.dart` | 4 | 기존 알파·강도 합성, 5:6 중앙 자르기, 실제 light PNG 색상 반영, 입력 검증 |
| `test/photo_repository_test.dart` | 3 | 저장소 재시작·정렬, 앨범 저장 실패 롤백, 손상 및 누락 파일 건너뛰기 |
| `test/camera_session_test.dart` | 4 | 초기화·종료 경합, 촬영 실패와 중복 방지, 취득 중 해제 지연, 카메라 없음과 권한 거부 |
| `test/camera_queue_test.dart` | 3 | 전후면 전환과 복귀 렌즈 유지·단일 렌즈, 센서 취득 중 전환 금지·저장 중 전환 허용·최대 3장 제한, 저장 실패 후 후속 처리와 종료 시 큐 소진 |
| `test/photo_processor_test.dart` | 3 | 임의 화면 비율 자르기·전면 원본만 반전 후 필터 합성, 실제 light/cold 캐시의 반복 출력과 직접 합성 일치, 작업 오류 및 처리기 종료 중 요청 완료 |
| `test/widget_test.dart` → `test/ui_checks.dart` | 8 | 하단 반투명 패널의 높이·투명도와 시스템 여백, 0→24픽셀→정상 크기 복구, 실제 썸네일 이미지 레이어와 선택 테두리, 즉시 촬영 피드백·저장 중 셔터 재활성·실패 안내, 전환 버튼 설명, 갤러리 왕복, 작은 화면·두 배 글자, 조회 재시도 |

큐 테스트는 각 사진의 필터·강도·화면 비율·전면 반전 정보를 고정하고 순서대로 처리하는지 확인했다. 이미지 처리기 테스트는 사전 로딩 후 각 PNG를 강도 0.5→1→1로 사용해 캐시 원본이 변경되지 않음을 출력 바이트 비교로 확인했다. 카메라와 앨범 저장은 테스트 대역이므로 실제 플러그인 성공을 뜻하지 않는다.

축소 UI 회귀 테스트는 360×640 화면에서 하단 시스템 여백 0 및 34픽셀일 때 조작부 높이가 화면의 3분의 1보다 작고 검정 배경의 알파가 0.28인지 확인했다. 선택 라벨과 촬영 조작부가 유지되고 기존 작은 화면·글자 확대 회귀도 함께 통과했다.

### 최신 테스트 파일 변경과 실행 이력

- 생성: `test/camera_queue_test.dart`, `test/photo_processor_test.dart`, `test/support/fake_photo_processor.dart`.
- 수정: `test/camera_session_test.dart`, `test/photo_compositor_test.dart`, `test/support/fake_camera.dart`, `test/ui_checks.dart`, 이 보고서.
- 이전 카운터 교체 진입점인 `test/widget_test.dart`는 유지한다.
- 최초 새 UI 테스트에서는 테스트가 소유한 세션의 비동기 종료를 기다리지 않아 타이머 잔존으로 실패했다. 종료 뒤 `pumpAndSettle`을 추가해 테스트 자원 정리를 완료했다. 운영 코드 결함으로 분류하지 않는다.
- 이번 자동 검증에서 새 운영 코드 결함은 발견하지 않았다.

### 메인 에이전트의 Android 에뮬레이터 직접 확인

- 기존 AVD의 메모리 부족과 저장 공간 문제는 별도 작업 공간 사용자 데이터와 메모리 4GB 구성으로 해결한 뒤 확인했다.
- 초기 설치 실패 시 Flutter가 기존 앱 제거·재설치를 시도했다. 기존 테스트 앱 내부 데이터 보존은 보장할 수 없으며, 이후 별도 QA 이미지에서도 ABI 변경에 따른 재설치로 앱 사본이 초기화되었다. AVD 전체 초기화는 수행하지 않았다.
- 일반 실행 및 카메라 권한 허용에 성공했다. 전면으로 전환해 에뮬레이션 장면이 바뀌고 후면 가상 장면으로 다시 복귀하는 두 방향 전환을 확인했다.
- 콜드 필터로 후면 사진을 촬영한 뒤 실제 기기 MediaStore에 항목 `_id=35`, 파일명 `1793609197607735_0.jpg`, 크기 720×1280이 생성된 것을 확인했다. 앱 갤러리 썸네일 갱신도 확인했다. 이 촬영 확인은 최종 조작부 축소 전 동일한 backend 코드에서 수행했다.
- 축소된 최종 일반 APK를 다시 설치하고 실행한 뒤 메인이 `build/camera_ui_final.png`를 직접 확인했다. 하단 패널은 화면의 약 26.6%이며 선택 라벨이 패널 위에 분리되고 실제 예시 이미지 썸네일 3개가 표시되는 것을 확인했다.
- 확인한 실행에서 Flutter 오류 등급 E 로그는 없었다.
- 축소된 최종 APK에서도 첫 사진이 `pendingSaves=1`, `isCapturing=false`인 상태를 메인이 VM 필드로 직접 관측하고 두 번째 셔터를 입력했다. 이후 MediaStore 항목 `_id=38`, `_id=39`에 각각 720×1280 사진이 생성되어 저장 중 추가 촬영과 두 작업의 실제 저장 완료를 확인했다.
- 메인은 최종 앱 갤러리에 사진 4장이 표시되는 화면을 `build/gallery_final.png`로 직접 검토했다. 최종 카메라 화면은 `build/camera_ui_final.png`에 기록했다. 이 추가 확인에서도 Flutter 오류 등급 E 로그는 없었다.
- 디버그 에뮬레이터에서 세션 측정값은 센서 촬영과 바이트 취득 **2.512854초**, 합성과 앨범 저장 **7.338967초**였다. 물리 기기의 성능 측정값이 아니며 지연 없는 촬영이나 즉시 저장을 보장하지 않는다. 저장이 끝나기 전 다음 촬영 버튼이 재활성화되는 동작은 자동 테스트로 별도 확인했다.
- 같은 디버그 에뮬레이터의 처리기 준비 후 추가 촬영에서는 마지막 측정값이 센서 촬영·바이트 취득 **1.565680초**, 합성·저장 **3.772486초**였다. 앞의 콜드 촬영 측정과 구분하며 동일 조건의 반복 성능 비교나 물리 기기 성능 보장으로 해석하지 않는다.

### 아직 남은 검증

- 센서 취득과 저장 분리, 3장 상한 및 UI 피드백은 구조와 대역 테스트로 확인했다. 실제 기기에서 촬영 지연이 얼마나 줄었는지는 측정하지 않았다.
- 실제 전면 카메라의 거울 표시, 미리보기와 최종 파일의 전체 화면 구도·회전·색감 일치는 기기별 확인이 필요하다.
- 물리 Android/iOS 기기, iOS 빌드, 다양한 해상도의 메모리와 발열 검증은 별도로 남는다.

## 최초 구현 검증 이력

## 추가 검증: 앱 실행 시 화면 크기 초기화 오류

- Android 17 에뮬레이터에서 사용자와 동일한 `_elements.contains(element)` 오류를 재현했다. 첫 예외는 `camera_screen.dart`에서 발생한 `BoxConstraints(w=-40.0)` 음수 너비였다.
- 화면 크기가 준비되기 전에 미리보기 레이아웃을 만들지 않도록 수정했다.
- 0 너비 → 24 너비 → 정상 크기로 전환하는 회귀 테스트가 수정 전 실패하고 수정 후 통과했다.
- 수정 후 `flutter analyze --no-pub` 문제 없음, `flutter test --no-pub` 전체 **17개 통과**.
- `flutter run -d emulator-5554 --no-pub`로 APK를 재빌드·설치하고 새로 실행했다. 첫 화면을 실제 에뮬레이터 캡처로 확인했고 해당 프로세스 로그에서 Flutter 예외가 나타나지 않았다.
- 캡처: `build/startup_after_fix.png`. 실제 한글 표시도 확인했으나 실제 휴대폰의 촬영·저장·색감 검증은 여전히 별도로 필요하다.
- 아래 결과는 최초 팀 구현 검증 당시의 기록이다.

## 결과

- `flutter analyze --no-pub`: 문제 없음.
- `flutter test --no-pub`: 16개 테스트 전체 통과.
- `dart format test`: 최종 실행 시 변경 없음.
- `flutter build apk --debug --no-pub`: 매니페스트 충돌 수정 후 재빌드 성공(138.7초). 산출물은 `build/app/outputs/flutter-apk/app-debug.apk`다.
- 실제 Android/iOS 기기를 사용한 촬영과 기기 앨범 검증은 수행하지 못했다.

## 자동 테스트 범위

| 파일 | 수 | 확인한 동작 |
|---|---:|---|
| `test/photo_compositor_test.dart` | 4 | 알려진 픽셀의 원래 알파와 강도 합성, 가로 원본의 중앙 5:6 크롭, 실제 제공 PNG의 저장 이미지 색상 변화, 잘못된 입력 거부 |
| `test/photo_repository_test.dart` | 3 | 앨범 저장 함수 호출 및 새 인스턴스의 최신순 재조회, 저장 실패 시 이미지·메타데이터 롤백, 손상된 메타데이터와 삭제된 사본 건너뛰기 |
| `test/camera_session_test.dart` | 4 | 초기화 중 종료 경합, 중복 촬영 거부 및 실패 후 상태 복구, 촬영 바이트를 읽기 전 카메라 해제 방지, 카메라 없음 및 권한 거부 안내 |
| `test/widget_test.dart` → `test/ui_checks.dart` | 5 | 권한 안내와 필터 변경, 저장 중 조작 제한 및 실패 안내, 빈 갤러리 왕복 시 카메라 복구, 320×568 및 글자 배율 2의 레이아웃, 조회 실패 후 재시도 |

카메라와 기기 앨범 쓰기는 테스트 대역을 사용했다. 테스트 통과는 실제 플러그인 및 기기 동작 성공을 뜻하지 않는다. 단위 테스트는 임시 디렉터리를 생성하고 종료 시 정리한다.

## 발견 및 수정한 결함

- 최초 전체 테스트에서 15개 통과, 1개 실패했다.
- 갤러리의 `_reload`가 `setState` 콜백에서 `Future`를 반환해 다시 불러오기와 새로고침 시 Flutter 단언 오류가 발생했다.
- frontend 담당자가 콜백을 동기 블록으로 변경했고, 동일 회귀 테스트를 포함한 최종 16개가 모두 통과했다.
- 최초 Android 빌드는 앱의 `WRITE_EXTERNAL_STORAGE` 권한 `maxSdkVersion=29`와 `camera_android_camerax`의 `maxSdkVersion=28` 충돌로 `:app:processDebugMainManifest`에서 실패했다. backend 담당자가 `tools:replace="android:maxSdkVersion"` 선언으로 앱의 필요한 범위를 유지하도록 수정했고 재빌드가 성공했다.

## 환경과 실행 명령

- Windows, Flutter 3.47.9, Dart 3.13.7.
- `flutter devices`: Windows, Chrome, Edge만 확인. 연결된 Android/iOS 기기 없음.
- `flutter doctor -v`: Android SDK 36.1과 Android Studio JDK 21 확인. 일부 Android 라이선스 미수락 경고가 있고 Windows용 Visual Studio는 설치되어 있지 않다.
- 실행: `dart format test`, 개별 `flutter test ... --no-pub`, 최종 `flutter analyze --no-pub`, `flutter test --no-pub`, `flutter build apk --debug --no-pub`.
- Android 최초 빌드는 기존 수락된 라이선스로 Android SDK Platform 35 설치를 완료한 뒤 매니페스트 병합에서 실패했다(243.6초).
- 선택적 `flutter test --no-pub --dart-define=UI_QA=true`는 첫 화면 파일 생성 후 캡처 보조 코드에서 진행되지 않아 중단했다. 보조 코드는 제거했고 일반 테스트를 다시 실행해 통과했다.
- 첫 화면 이미지는 임시 경로 `C:/Users/dongg/AppData/Local/Temp/aeroll_ui_qa/camera_permission.png`에 생성했다. 메인 에이전트가 390×844 레이아웃 구조와 오버플로 없음만 확인했다. 테스트 기본 글꼴이 Ahem이므로 실제 한글 가독성 및 글꼴 시각 검증은 완료하지 않았다.

## 생성 및 수정 파일

- 생성: `test/photo_compositor_test.dart`, `test/photo_repository_test.dart`, `test/camera_session_test.dart`, `test/support/fake_camera.dart`, `test/ui_checks.dart`, `docs/test_report.md`.
- 수정: `test/widget_test.dart`의 기본 카운터 테스트를 실제 UI 검증 진입점으로 교체했다.
- tester는 앱 운영 코드를 직접 수정하지 않았다. 갤러리 결함은 frontend 담당자가 수정했다.

## 남은 확인 사항

- Android/iOS 실기기에서 카메라 초기화와 권한 거부·재허용, 백그라운드 전환 및 복귀.
- 카메라 미리보기와 저장 사진의 실제 구도, 이미지 회전 및 필터 색상 일치.
- 실제 기기 앨범 쓰기 권한, 저장 성공과 실패, 앱 재시작 후 조회.
- iOS 빌드 및 플러그인 연동은 macOS/Xcode 환경에서 확인해야 한다.
- 고해상도 촬영의 메모리 사용량과 처리 시간, 실제 글꼴의 가독성.
- 앱 갤러리는 앱 전용 사본을 사용하므로 기기 앨범에서 사진을 삭제해도 앱 사본은 남는다.
