// 렌더러(웹앱)에 데스크톱 기능만 좁게 노출한다. 웹앱은 window.pdfAgent가 있을 때만 이 기능을 쓴다.
'use strict';

const { contextBridge, ipcRenderer, webUtils } = require('electron');

contextBridge.exposeInMainWorld('pdfAgent', {
  // 네이티브 열기 대화상자 → { name, path, data } 또는 null
  openDialog: () => ipcRenderer.invoke('dialog:open'),
  // PDF 바이트 저장 → { canceled, path, name }
  savePdf: (opts) => ipcRenderer.invoke('file:save', opts),
  // 끌어다 놓은 파일의 실제 경로 (저장 대화상자의 기본 폴더로 사용)
  getPathForFile: (file) => {
    try {
      return webUtils.getPathForFile(file) || null;
    } catch (e) {
      return null;
    }
  },
  showItemInFolder: (filePath) => ipcRenderer.send('shell:showItem', filePath),
  setDirty: (value) => ipcRenderer.send('state:dirty', !!value),
  onOpenFile: (cb) => ipcRenderer.on('file:opened', (_e, file) => cb(file)),
  onCommand: (cb) => ipcRenderer.on('menu:command', (_e, command) => cb(command)),
  ready: () => ipcRenderer.send('renderer:ready'),
});
