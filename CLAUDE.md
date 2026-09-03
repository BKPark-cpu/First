# 프로젝트 메모

## 로컬 작업 디렉터리

바이브 코딩 결과물은 Windows 로컬 경로 `C:\BK\Vibecoding` 아래에 둔다.
원격(클라우드) 세션에서는 이 경로에 직접 쓸 수 없으므로, 작업은 GitHub 브랜치로
푸시하고 로컬에서 해당 폴더로 clone/pull 해서 받는다.

```powershell
cd C:\BK\Vibecoding
git clone https://github.com/BKPark-cpu/First.git
```

## Playwright

- npm 설치본에는 전역 `playwright` 명령이 없다. 항상 `npx playwright ...` 로 실행한다.
- 브라우저는 최초 1회 `npx playwright install chromium` 으로 받는다.
- CI/컨테이너처럼 브라우저가 미리 설치된 환경에서는 `lib/chromium.js` 가
  `PLAYWRIGHT_BROWSERS_PATH` 아래의 chromium 을 찾아 재사용한다.
- 테스트 실행: `npx playwright test`
