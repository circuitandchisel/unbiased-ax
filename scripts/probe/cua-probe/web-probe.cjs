// ProbeWeb: the same question asked of a Chromium surface, because the app we
// actually care about is one. If an agent reaches a browser-engine app through
// the renderer rather than through the window, the page records the click and
// the native side and the system tap both stay silent.
const { app, BrowserWindow } = require("electron");
const fs = require("fs");
const os = require("os");
const path = require("path");

const dir = path.join(os.homedir(), "cua-probe");
fs.mkdirSync(dir, { recursive: true });
const LOG = path.join(dir, "probe.jsonl");
const started = Date.now();
const say = (src, fields) =>
  fs.appendFileSync(LOG, JSON.stringify({ src, t: Date.now() - started, wall: new Date().toISOString(), ...fields }) + "\n");

const html = `<!doctype html><title>ProbeWeb</title>
<style>
 html,body{margin:0;height:100%;background:#eef;font:12px ui-monospace,monospace;color:#233}
 #canvas{position:absolute;left:16px;top:56px;width:760px;height:360px;background:#dde;border:2px solid #99a}
 button{position:absolute;top:436px;width:120px;height:32px;font:inherit}
 #wa{left:16px}#wb{left:150px}#wc{left:284px}
 input{position:absolute;left:430px;top:436px;width:340px;height:26px;font:inherit}
 #out{position:absolute;left:16px;top:480px}
 h1{font:600 14px ui-monospace,monospace;margin:16px}
</style>
<h1>ProbeWeb — clicks here are written to ~/cua-probe/probe.jsonl</h1>
<div id="canvas"></div>
<button id="wa">WEB-A</button><button id="wb">WEB-B</button><button id="wc">WEB-C</button>
<input id="wf" placeholder="WEB-TYPE-HERE">
<div id="out">0 events</div>
<script>
 let n = 0;
 const post = (o) => { n++; document.getElementById("out").textContent = n + " events";
   window.__probe && window.__probe(JSON.stringify(o)); };
 const of = (e) => ({ type: e.type, x: e.clientX, y: e.clientY, sx: e.screenX, sy: e.screenY,
   detail: e.detail, buttons: e.buttons, trusted: e.isTrusted,
   target: (e.target && (e.target.id || e.target.tagName)) || "?",
   pointerType: e.pointerType });
 for (const t of ["mousedown","mouseup","click","dblclick","contextmenu","pointerdown","pointerup"])
   document.addEventListener(t, (e) => post(of(e)), true);
 // Moves are a trail: sample them, do not flood.
 let lastMove = 0;
 document.addEventListener("mousemove", (e) => { const now = performance.now();
   if (now - lastMove > 40) { lastMove = now; post(of(e)); } }, true);
 document.addEventListener("keydown", (e) => post({ type: "keydown", key: e.key, trusted: e.isTrusted }), true);
 for (const t of ["focus","blur"]) window.addEventListener(t, () => post({ type: t, hasFocus: document.hasFocus() }));
 document.getElementById("wf").addEventListener("input", (e) => post({ type: "input", value: e.target.value }));
</script>`;

app.whenReady().then(() => {
  const win = new BrowserWindow({
    width: 800, height: 560, x: 1060, y: 120, show: false, title: "ProbeWeb",
    alwaysOnTop: true,
    webPreferences: { preload: path.join(__dirname, "web-preload.cjs") },
  });
  win.loadURL("data:text/html;charset=utf-8," + encodeURIComponent(html));
  win.once("ready-to-show", () => {
    win.showInactive();
    say("state", { kind: "webLaunched", pid: process.pid, bounds: win.getBounds() });
  });
  win.on("focus", () => say("state", { kind: "webWindowFocused" }));
  win.on("blur", () => say("state", { kind: "webWindowBlurred" }));
  require("electron").ipcMain.on("probe", (_e, json) => {
    let o = {}; try { o = JSON.parse(json); } catch {}
    say("web", o);
  });
});
