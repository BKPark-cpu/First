# PDF 편집 에이전트 (데스크톱 앱)

저장소 루트의 웹앱 `pdf-editor.html`을 Electron으로 감싼 데스크톱 앱입니다.
PDF에 텍스트·이미지·하이라이트·도형(사각형·원형)·펜을 추가하고, 실행취소/다시실행을 할 수 있습니다.

## 웹앱과 다른 점
- **오프라인 동작**: pdf.js, pdf-lib, fontkit, 나눔고딕, Pretendard를 앱 안에 포함합니다.
- **네이티브 파일 열기·저장**: 처음 저장할 때 저장 위치를 묻고, 이후 `Ctrl+S`는 같은 파일에 바로 저장합니다.
  `Ctrl+Shift+S`는 다른 이름으로 저장합니다.
- **PDF 파일 연결**: 설치 후 탐색기에서 PDF를 오른쪽 클릭 → "연결 프로그램"으로 열 수 있습니다.
- **저장 안 한 변경 확인**: 편집 후 저장하지 않고 창을 닫거나 다른 PDF를 열면 확인 창을 띄웁니다.
- **메뉴**: 파일 / 편집 / 보기 / 도움말(오픈소스 라이선스 보기 포함)

## 실행 방법 (개발 모드)
[Node.js](https://nodejs.org/) 20 이상이 필요합니다.

```bash
cd desktop
npm install
npm start
```

`npm start`는 `scripts/build-renderer.js`로 `../pdf-editor.html`을 `app/index.html`로 변환한 뒤 앱을 띄웁니다.
웹앱을 수정했다면 `npm start`를 다시 실행하면 반영됩니다.

## 설치 파일 만들기
설치 파일은 해당 운영체제에서 만드는 것이 가장 확실합니다.

```bash
npm run dist:win    # Windows 설치 파일 (dist/pdf-edit-agent-<버전>-win-x64.exe)
npm run dist:mac    # macOS dmg
npm run dist:linux  # Linux AppImage
```

코드 서명을 하지 않은 설치 파일이라 Windows에서 "PC 보호" 경고가 뜰 수 있습니다. **추가 정보 → 실행**을 누르면 설치됩니다.

## 폴더 구조
| 경로 | 설명 |
|---|---|
| `main.js` | Electron 메인 프로세스: 창, 메뉴, 파일 열기·저장, `app://` 프로토콜 |
| `preload.js` | 웹앱에 노출하는 데스크톱 API(`window.pdfAgent`) |
| `scripts/build-renderer.js` | 웹앱 → 데스크톱 화면 변환(CDN 주소를 로컬 파일로 교체, CSP 추가) |
| `THIRD_PARTY_NOTICES.md` | 서드파티 라이선스 고지 |
| `build/icon.png` | 앱 아이콘 |
| `app/`, `dist/` | 빌드 결과물 (git에 올리지 않음) |

## 보안 설정
- `contextIsolation`, `sandbox`를 켜고 `nodeIntegration`을 껐습니다. 웹앱은 preload가 노출한 몇 가지 기능만 쓸 수 있습니다.
- 화면은 `app://` 프로토콜로 `app/` 폴더 안의 파일만 제공하고, Content-Security-Policy로 외부 리소스를 막습니다.
- 렌더러는 사용자가 저장 대화상자에서 고른 경로에만 파일을 쓸 수 있습니다.

## 라이선스 고지
편집 로직은 [ShizukuIchi/pdf-editor](https://github.com/ShizukuIchi/pdf-editor)(MIT License, Copyright (c) 2020 ShizukuIchi)를 참고했습니다.
고지는 아래 위치에 들어 있습니다.
- `pdf-editor.html` 상단 주석: 참고 레포와 라이선스, 참고한 부분 목록
- `THIRD_PARTY_NOTICES.md`: MIT 라이선스 전문과 함께 포함한 라이브러리·글꼴의 라이선스. 앱 안에서는 **도움말 → 오픈소스 라이선스**로 볼 수 있습니다.
- 배포 패키지 안의 `app/vendor/licenses/`: 포함한 라이브러리의 라이선스 원문
