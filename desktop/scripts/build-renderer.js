// 저장소 루트의 웹앱(pdf-editor.html)을 데스크톱 앱 화면(app/index.html)으로 변환한다.
//  - CDN에서 받던 라이브러리·폰트를 node_modules에서 app/vendor로 복사하고 경로를 바꿔 오프라인에서도 동작하게 한다.
//  - Content-Security-Policy를 넣고 제목을 데스크톱 앱 이름으로 바꾼다.
//  - 원본 HTML의 라이선스 고지 주석(ShizukuIchi/pdf-editor, MIT)은 그대로 유지된다.
'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const SOURCE = path.resolve(ROOT, '..', 'pdf-editor.html');
const OUT_DIR = path.join(ROOT, 'app');
const VENDOR_DIR = path.join(OUT_DIR, 'vendor');
const LICENSE_DIR = path.join(VENDOR_DIR, 'licenses');
const NM = path.join(ROOT, 'node_modules');
const APP_NAME = 'PDF 편집 에이전트';

// CDN 주소 → [로컬 경로, node_modules 안의 원본 파일]
const ASSETS = {
  'https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.min.js':
    ['vendor/pdf.min.js', 'pdfjs-dist/build/pdf.min.js'],
  'https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.worker.min.js':
    ['vendor/pdf.worker.min.js', 'pdfjs-dist/build/pdf.worker.min.js'],
  'https://cdnjs.cloudflare.com/ajax/libs/pdf-lib/1.17.1/pdf-lib.min.js':
    ['vendor/pdf-lib.min.js', 'pdf-lib/dist/pdf-lib.min.js'],
  'https://unpkg.com/@pdf-lib/fontkit@1.1.1/dist/fontkit.umd.min.js':
    ['vendor/fontkit.umd.min.js', '@pdf-lib/fontkit/dist/fontkit.umd.min.js'],
  'https://cdn.jsdelivr.net/npm/@kfonts/nanum-gothic@0.2.0/NanumGothic.woff':
    ['vendor/NanumGothic.woff', '@kfonts/nanum-gothic/NanumGothic.woff'],
  'https://cdn.jsdelivr.net/gh/orioncactus/pretendard@v1.3.9/dist/web/variable/pretendardvariable-dynamic-subset.min.css':
    ['vendor/pretendard.css', null], // 아래에서 직접 생성
};

// 함께 배포하는 서드파티 라이선스 원문
const LICENSES = {
  'pdfjs-dist.LICENSE.txt': 'pdfjs-dist/LICENSE',
  'pdf-lib.LICENSE.md': 'pdf-lib/LICENSE.md',
  'pretendard.LICENSE.txt': 'pretendard/dist/LICENSE.txt',
  'electron.LICENSE.txt': 'electron/LICENSE',
};

const CSP = [
  "default-src 'self'",
  "script-src 'self' 'unsafe-inline'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: blob:",
  "font-src 'self' data:",
  "connect-src 'self' data: blob:",
  "worker-src 'self' blob:",
  "object-src 'none'",
  "base-uri 'none'",
  "form-action 'none'",
].join('; ');

function copy(from, to) {
  fs.mkdirSync(path.dirname(to), { recursive: true });
  fs.copyFileSync(from, to);
}

function main() {
  if (!fs.existsSync(SOURCE)) throw new Error(`웹앱 원본을 찾을 수 없습니다: ${SOURCE}`);
  let html = fs.readFileSync(SOURCE, 'utf8');

  fs.rmSync(OUT_DIR, { recursive: true, force: true });
  fs.mkdirSync(VENDOR_DIR, { recursive: true });

  for (const [url, [local, src]] of Object.entries(ASSETS)) {
    if (!html.includes(url)) throw new Error(`원본 HTML에서 다음 주소를 찾지 못했습니다(버전이 바뀌었나요?): ${url}`);
    html = html.split(url).join(local);
    if (src) copy(path.join(NM, src), path.join(OUT_DIR, local));
  }

  // Pretendard 가변 폰트 (CDN의 동적 서브셋 CSS 대신 단일 woff2 파일 사용)
  copy(path.join(NM, 'pretendard/dist/web/variable/woff2/PretendardVariable.woff2'),
    path.join(VENDOR_DIR, 'PretendardVariable.woff2'));
  fs.writeFileSync(path.join(VENDOR_DIR, 'pretendard.css'), `@font-face {
  font-family: "Pretendard Variable";
  font-weight: 45 920;
  font-style: normal;
  font-display: swap;
  src: url("PretendardVariable.woff2") format("woff2-variations");
}
`);

  // 바꾸지 못한 외부 주소가 남아 있으면 오프라인에서 깨지므로 빌드를 멈춘다.
  const leftover = html.match(/(?:src|href)="https?:\/\/[^"]+"|'https?:\/\/(?:cdnjs|unpkg|cdn\.jsdelivr)[^']+'/g);
  if (leftover) throw new Error('로컬로 바꾸지 못한 외부 리소스가 있습니다:\n' + leftover.join('\n'));

  html = html
    .replace('<meta charset="UTF-8">', `<meta charset="UTF-8">\n<meta http-equiv="Content-Security-Policy" content="${CSP}">`)
    .replace('<title>PDF 편집기</title>', `<title>${APP_NAME}</title>`)
    .replace('<h1>PDF 편집기</h1>', `<h1>${APP_NAME}</h1>`);
  fs.writeFileSync(path.join(OUT_DIR, 'index.html'), html);

  for (const [name, src] of Object.entries(LICENSES)) copy(path.join(NM, src), path.join(LICENSE_DIR, name));
  copy(path.join(ROOT, 'THIRD_PARTY_NOTICES.md'), path.join(OUT_DIR, 'THIRD_PARTY_NOTICES.md'));

  console.log(`app/index.html 생성 완료 (${Object.keys(ASSETS).length}개 리소스를 로컬로 전환)`);
}

main();
