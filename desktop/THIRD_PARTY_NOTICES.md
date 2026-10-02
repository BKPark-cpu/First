# 서드파티 라이선스 고지 (Third-Party Notices)

PDF 편집 에이전트는 아래 오픈소스 소프트웨어를 참고하거나 포함하고 있습니다.
각 소프트웨어의 저작권은 해당 저작권자에게 있습니다.

---

## ShizukuIchi/pdf-editor — 참고한 소스 코드

- 레포지토리: https://github.com/ShizukuIchi/pdf-editor
- 라이선스: MIT License
- 사용 방식: PDF 렌더링·좌표 환산, 이미지 리사이즈 핸들과 비율 유지 계산, 이미지 PNG 변환,
  자유 그리기의 SVG path 저장 방식, pdf-lib 기반 저장 흐름, 파일 읽기 유틸의 로직을 참고해
  바닐라 JavaScript로 다시 작성했습니다. 자세한 대응 관계는 `pdf-editor.html` 상단 주석에 있습니다.

```
The MIT License (MIT)

Copyright (c) 2020 ShizukuIchi

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 포함한 라이브러리

| 이름 | 버전 | 라이선스 | 저작권 | 원문 |
|---|---|---|---|---|
| PDF.js (pdfjs-dist) | 3.11.174 | Apache License 2.0 | Mozilla Foundation and contributors | `vendor/licenses/pdfjs-dist.LICENSE.txt` |
| pdf-lib | 1.17.1 | MIT License | Copyright (c) 2019 Andrew Dillon | `vendor/licenses/pdf-lib.LICENSE.md` |
| @pdf-lib/fontkit | 1.1.1 | MIT License | Copyright (c) Devon Govett, Andrew Dillon | 아래 MIT 전문 |
| Electron | 44.5.1 | MIT License | Copyright (c) Electron contributors, GitHub Inc. | `vendor/licenses/electron.LICENSE.txt` |

### @pdf-lib/fontkit — MIT License

```
Copyright (c) Devon Govett, Andrew Dillon

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Electron 배포판에는 Chromium과 그 구성 요소의 라이선스(`LICENSES.chromium.html`)가 함께 포함됩니다.

---

## 포함한 글꼴

| 이름 | 라이선스 | 저작권 | 비고 |
|---|---|---|---|
| 나눔고딕 (NanumGothic) | SIL Open Font License 1.1 | Copyright (c) NAVER Corporation | PDF에 한글 텍스트를 넣을 때 임베드 (@kfonts/nanum-gothic 0.2.0) |
| Pretendard | SIL Open Font License 1.1 | Copyright (c) 2021, Kil Hyung-jin, with Reserved Font Name Pretendard | 화면 UI 글꼴. 원문: `vendor/licenses/pretendard.LICENSE.txt` |

SIL Open Font License 1.1 전문: https://openfontlicense.org/open-font-license-official-text/

---

## 디자인

화면 디자인은 토스 디자인 시스템(TDS)의 색상·컴포넌트 스타일을 참고해 CSS로 직접 구현했습니다.
TDS의 코드나 에셋은 포함하지 않았습니다.
