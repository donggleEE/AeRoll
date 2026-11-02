# 카메라·필터·갤러리 검증 결과

## 최신 검증: 전체 화면·전후면 전환·촬영 응답성 개선

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
