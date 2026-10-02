// PDF 편집 에이전트 — Electron 메인 프로세스
//
// 화면(app/index.html)은 저장소 루트의 웹앱 pdf-editor.html을 빌드한 것이며,
// 그 편집 로직은 ShizukuIchi/pdf-editor(https://github.com/ShizukuIchi/pdf-editor, MIT License,
// Copyright (c) 2020 ShizukuIchi)를 참고했습니다. 전체 고지는 THIRD_PARTY_NOTICES.md를 참고하세요.
'use strict';

const { app, BrowserWindow, Menu, dialog, ipcMain, protocol, net, shell } = require('electron');
const fs = require('fs');
const path = require('path');
const { pathToFileURL } = require('url');

const APP_NAME = 'PDF 편집 에이전트';
const APP_DIR = path.join(__dirname, 'app');
const SCHEME = 'app';
const ORIGIN = `${SCHEME}://pdf-agent`;

app.setName(APP_NAME);

// file:// 에서는 fetch·Worker가 막히므로 app:// 사용자 정의 프로토콜로 화면을 제공한다.
protocol.registerSchemesAsPrivileged([
  { scheme: SCHEME, privileges: { standard: true, secure: true, supportFetchAPI: true } },
]);

let mainWindow = null;
let licenseWindow = null;
let rendererReady = false;
let dirty = false;
const pendingOpen = [];
// 렌더러가 임의 경로에 쓰지 못하도록, 사용자가 대화상자에서 고른 경로만 다시 저장을 허용한다.
const approvedSavePaths = new Set();

// ---- 단일 인스턴스: 이미 실행 중이면 그 창에서 파일을 연다 ----
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', (_e, argv) => {
    const file = pdfFromArgs(argv);
    if (file) openPath(file);
    if (mainWindow) {
      if (mainWindow.isMinimized()) mainWindow.restore();
      mainWindow.focus();
    }
  });
}

function pdfFromArgs(argv) {
  return argv.slice(1).find((a) => /\.pdf$/i.test(a) && fs.existsSync(a)) || null;
}

// macOS: Finder에서 "다음으로 열기"
app.on('open-file', (e, file) => {
  e.preventDefault();
  openPath(file);
});

// ---- 파일 열기 ----
async function openPath(filePath) {
  if (mainWindow && rendererReady && !(await confirmDiscard())) return;
  try {
    const data = await fs.promises.readFile(filePath);
    const payload = { name: path.basename(filePath), path: filePath, data: new Uint8Array(data) };
    if (mainWindow && rendererReady) mainWindow.webContents.send('file:opened', payload);
    else pendingOpen.push(payload);
    app.addRecentDocument(filePath);
  } catch (e) {
    dialog.showErrorBox(APP_NAME, `파일을 열 수 없어요.\n${filePath}\n\n${e.message}`);
  }
}

async function confirmDiscard() {
  if (!dirty) return true;
  const { response } = await dialog.showMessageBox(mainWindow, {
    type: 'warning',
    buttons: ['저장하지 않고 계속', '취소'],
    defaultId: 1,
    cancelId: 1,
    title: APP_NAME,
    message: '저장하지 않은 변경 사항이 있어요',
    detail: '계속하면 지금까지 편집한 내용이 사라져요.',
  });
  return response === 0;
}

async function showOpenDialog() {
  if (!(await confirmDiscard())) return null;
  const { canceled, filePaths } = await dialog.showOpenDialog(mainWindow, {
    title: 'PDF 열기',
    properties: ['openFile'],
    filters: [{ name: 'PDF 문서', extensions: ['pdf'] }],
  });
  if (canceled || !filePaths.length) return null;
  const filePath = filePaths[0];
  const data = await fs.promises.readFile(filePath);
  app.addRecentDocument(filePath);
  return { name: path.basename(filePath), path: filePath, data: new Uint8Array(data) };
}

// ---- IPC ----
ipcMain.handle('dialog:open', () => showOpenDialog());

ipcMain.handle('file:save', async (_e, opts) => {
  const { data, suggestedName, sourcePath, targetPath, forceDialog } = opts || {};
  if (!(data instanceof Uint8Array) || data.length < 5) throw new Error('잘못된 PDF 데이터');
  if (Buffer.from(data.subarray(0, 5)).toString('latin1') !== '%PDF-') throw new Error('PDF 형식이 아닌 데이터');

  let filePath = !forceDialog && targetPath && approvedSavePaths.has(targetPath) ? targetPath : null;
  if (!filePath) {
    const baseDir = sourcePath ? path.dirname(sourcePath) : app.getPath('documents');
    const name = path.basename(String(suggestedName || 'edited.pdf'));
    const result = await dialog.showSaveDialog(mainWindow, {
      title: '다른 이름으로 저장',
      defaultPath: path.join(baseDir, name),
      filters: [{ name: 'PDF 문서', extensions: ['pdf'] }],
    });
    if (result.canceled || !result.filePath) return { canceled: true };
    filePath = /\.pdf$/i.test(result.filePath) ? result.filePath : result.filePath + '.pdf';
    approvedSavePaths.add(filePath);
  }
  await fs.promises.writeFile(filePath, data);
  app.addRecentDocument(filePath);
  return { canceled: false, path: filePath, name: path.basename(filePath) };
});

ipcMain.on('state:dirty', (_e, value) => {
  dirty = !!value;
  if (mainWindow) mainWindow.setDocumentEdited(dirty);
});

ipcMain.on('renderer:ready', () => {
  rendererReady = true;
  while (pendingOpen.length) mainWindow.webContents.send('file:opened', pendingOpen.shift());
});

ipcMain.on('shell:showItem', (_e, filePath) => {
  if (approvedSavePaths.has(filePath)) shell.showItemInFolder(filePath);
});

// ---- 창 ----
function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1200,
    height: 900,
    minWidth: 420,
    minHeight: 500,
    title: APP_NAME,
    backgroundColor: '#f2f4f6',
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      spellcheck: false,
    },
  });
  mainWindow.once('ready-to-show', () => mainWindow.show());

  // 외부 페이지 이동과 새 창 열기를 막고, 링크는 기본 브라우저로 연다.
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:\/\//.test(url)) shell.openExternal(url);
    return { action: 'deny' };
  });
  mainWindow.webContents.on('will-navigate', (e, url) => {
    if (!url.startsWith(ORIGIN)) e.preventDefault();
  });

  mainWindow.on('close', (e) => {
    if (!dirty) return;
    const choice = dialog.showMessageBoxSync(mainWindow, {
      type: 'warning',
      buttons: ['저장하지 않고 닫기', '취소'],
      defaultId: 1,
      cancelId: 1,
      title: APP_NAME,
      message: '저장하지 않은 변경 사항이 있어요',
      detail: '창을 닫으면 지금까지 편집한 내용이 사라져요.',
    });
    if (choice !== 0) e.preventDefault();
  });
  mainWindow.on('closed', () => {
    mainWindow = null;
    rendererReady = false;
  });

  mainWindow.loadURL(`${ORIGIN}/index.html`);
}

function showLicenses() {
  if (licenseWindow) {
    licenseWindow.focus();
    return;
  }
  licenseWindow = new BrowserWindow({
    width: 760,
    height: 720,
    title: '오픈소스 라이선스',
    parent: mainWindow || undefined,
    webPreferences: { contextIsolation: true, nodeIntegration: false, sandbox: true },
  });
  licenseWindow.setMenu(null);
  licenseWindow.loadURL(`${ORIGIN}/THIRD_PARTY_NOTICES.md`);
  licenseWindow.on('closed', () => { licenseWindow = null; });
}

// ---- 메뉴 ----
// 실행취소·저장 같은 단축키는 메뉴가 받아서 렌더러에 명령으로 전달한다.
function send(command) {
  if (mainWindow) mainWindow.webContents.send('menu:command', command);
}

function buildMenu() {
  const isMac = process.platform === 'darwin';
  const template = [
    ...(isMac ? [{ role: 'appMenu' }] : []),
    {
      label: '파일',
      submenu: [
        { label: '열기…', accelerator: 'CmdOrCtrl+O', click: () => send('open') },
        { type: 'separator' },
        { label: '저장', accelerator: 'CmdOrCtrl+S', click: () => send('save') },
        { label: '다른 이름으로 저장…', accelerator: 'CmdOrCtrl+Shift+S', click: () => send('saveAs') },
        { type: 'separator' },
        isMac ? { role: 'close', label: '창 닫기' } : { role: 'quit', label: '종료' },
      ],
    },
    {
      label: '편집',
      submenu: [
        { label: '실행취소', accelerator: 'CmdOrCtrl+Z', click: () => send('undo') },
        { label: '다시실행', accelerator: isMac ? 'Cmd+Shift+Z' : 'Ctrl+Y', click: () => send('redo') },
        { type: 'separator' },
        { role: 'cut', label: '잘라내기' },
        { role: 'copy', label: '복사' },
        { role: 'paste', label: '붙여넣기' },
        { role: 'selectAll', label: '모두 선택' },
      ],
    },
    {
      label: '보기',
      submenu: [
        { role: 'resetZoom', label: '실제 크기' },
        { role: 'zoomIn', label: '확대' },
        { role: 'zoomOut', label: '축소' },
        { type: 'separator' },
        { role: 'togglefullscreen', label: '전체 화면' },
        ...(app.isPackaged ? [] : [{ role: 'toggleDevTools', label: '개발자 도구' }]),
      ],
    },
    {
      label: '도움말',
      submenu: [
        { label: '오픈소스 라이선스', click: showLicenses },
        {
          label: '참고한 오픈소스: ShizukuIchi/pdf-editor',
          click: () => shell.openExternal('https://github.com/ShizukuIchi/pdf-editor'),
        },
        { type: 'separator' },
        {
          label: `${APP_NAME} 정보`,
          click: () => dialog.showMessageBox(mainWindow, {
            title: APP_NAME,
            message: `${APP_NAME} ${app.getVersion()}`,
            detail: 'PDF에 텍스트·이미지·하이라이트·도형·펜을 추가하는 데스크톱 앱입니다.\n\n'
              + '편집 로직은 ShizukuIchi/pdf-editor (MIT License, Copyright (c) 2020 ShizukuIchi)를 참고했습니다.\n'
              + '자세한 내용은 도움말 > 오픈소스 라이선스를 확인하세요.',
          }),
        },
      ],
    },
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

// ---- 시작 ----
app.whenReady().then(() => {
  // app://pdf-agent/<경로> → app 폴더의 파일. 폴더 밖으로 나가는 경로는 거부한다.
  protocol.handle(SCHEME, async (request) => {
    const url = new URL(request.url);
    const rel = decodeURIComponent(url.pathname).replace(/^\/+/, '');
    const filePath = path.normalize(path.join(APP_DIR, rel));
    if (url.host !== 'pdf-agent' || !filePath.startsWith(APP_DIR + path.sep)) {
      return new Response('Not found', { status: 404 });
    }
    if (filePath.endsWith('.md')) {
      const text = await fs.promises.readFile(filePath, 'utf8');
      return new Response(text, { headers: { 'content-type': 'text/plain; charset=utf-8' } });
    }
    return net.fetch(pathToFileURL(filePath).toString());
  });

  buildMenu();
  createWindow();
  const initial = pdfFromArgs(process.argv);
  if (initial) openPath(initial);

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
