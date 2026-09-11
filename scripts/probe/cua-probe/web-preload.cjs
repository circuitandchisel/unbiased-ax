const { contextBridge, ipcRenderer } = require("electron");
// The page hands each event to the main process, which writes the shared log.
contextBridge.exposeInMainWorld("__probe", (json) => ipcRenderer.send("probe", json));
