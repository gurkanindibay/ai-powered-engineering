#!/usr/bin/env python3
"""Interactive Live Web Viewer for SitePulse Android Emulator."""

import os
import sys
import time
import subprocess
import urllib.parse
from http.server import HTTPServer, BaseHTTPRequestHandler

PORT = 9090
ADB = "/home/gurkanindibay/Android/Sdk/platform-tools/adb"

HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="tr">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>SitePulse - Android Live Emulator Test</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@400;600;700;800&display=swap" rel="stylesheet">
  <style>
    :root {
      --bg: #0b0f19;
      --card-bg: #151d2f;
      --primary: #00629e;
      --accent: #00d2ff;
      --text: #f8fafc;
      --text-muted: #94a3b8;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: 'Plus Jakarta Sans', sans-serif;
      background: radial-gradient(circle at top, #152238 0%, var(--bg) 100%);
      color: var(--text);
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      padding: 24px 16px;
    }
    header {
      text-align: center;
      margin-bottom: 20px;
    }
    header h1 {
      font-size: 26px;
      font-weight: 800;
      background: linear-gradient(135deg, #fff 0%, var(--accent) 100%);
      -webkit-background-clip: text;
      background-clip: text;
      -webkit-text-fill-color: transparent;
      letter-spacing: -0.5px;
    }
    header p {
      color: var(--text-muted);
      font-size: 14px;
      margin-top: 4px;
    }
    .badge {
      display: inline-block;
      padding: 4px 12px;
      border-radius: 999px;
      font-size: 11px;
      font-weight: 700;
      background: rgba(0, 210, 255, 0.15);
      color: var(--accent);
      margin-top: 8px;
      border: 1px solid rgba(0, 210, 255, 0.3);
    }
    .main-container {
      display: flex;
      flex-wrap: wrap;
      gap: 32px;
      justify-content: center;
      align-items: flex-start;
      max-width: 1050px;
      width: 100%;
    }
    /* Phone Shell */
    .phone-case {
      width: 370px;
      height: 780px;
      background: #000;
      border-radius: 46px;
      padding: 12px;
      box-shadow: 0 25px 60px -15px rgba(0, 0, 0, 0.8), 0 0 0 4px #2c384e, 0 0 30px rgba(0, 210, 255, 0.15);
      position: relative;
      user-select: none;
      flex-shrink: 0;
    }
    .screen-wrapper {
      width: 100%;
      height: 100%;
      border-radius: 36px;
      overflow: hidden;
      position: relative;
      background: #000;
      cursor: crosshair;
    }
    #screenImg {
      width: 100%;
      height: 100%;
      object-fit: cover;
      display: block;
    }
    .click-ripple {
      position: absolute;
      width: 24px;
      height: 24px;
      border-radius: 50%;
      background: rgba(0, 210, 255, 0.6);
      transform: translate(-50%, -50%) scale(0);
      animation: ripple 0.4s ease-out forwards;
      pointer-events: none;
    }
    @keyframes ripple {
      to { transform: translate(-50%, -50%) scale(2.5); opacity: 0; }
    }
    /* Controls Panel */
    .controls-panel {
      flex: 1;
      min-width: 300px;
      max-width: 460px;
      background: var(--card-bg);
      border-radius: 24px;
      padding: 24px;
      border: 1px solid rgba(255, 255, 255, 0.08);
      box-shadow: 0 10px 30px rgba(0,0,0,0.3);
    }
    .controls-panel h2 {
      font-size: 18px;
      margin-bottom: 12px;
      display: flex;
      align-items: center;
      gap: 8px;
    }
    .instructions {
      font-size: 13px;
      line-height: 1.6;
      color: var(--text-muted);
      margin-bottom: 20px;
      background: rgba(0,0,0,0.25);
      padding: 14px;
      border-radius: 14px;
    }
    .instructions strong { color: #fff; }
    .action-group {
      margin-bottom: 20px;
    }
    .action-group-title {
      font-size: 12px;
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: 0.5px;
      color: var(--text-muted);
      margin-bottom: 10px;
    }
    .btn-grid {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 10px;
    }
    button.action-btn {
      background: rgba(255, 255, 255, 0.06);
      border: 1px solid rgba(255, 255, 255, 0.12);
      color: #fff;
      padding: 12px 14px;
      border-radius: 14px;
      font-size: 13px;
      font-weight: 600;
      cursor: pointer;
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 8px;
      transition: all 0.2s;
    }
    button.action-btn:hover {
      background: rgba(255, 255, 255, 0.12);
      border-color: var(--accent);
      transform: translateY(-2px);
    }
    button.action-btn.primary {
      background: linear-gradient(135deg, #0052cc 0%, #0080ff 100%);
      grid-column: span 2;
      padding: 14px;
      font-size: 14px;
      font-weight: 700;
      border: none;
    }
    button.action-btn.primary:hover {
      box-shadow: 0 4px 15px rgba(0, 128, 255, 0.4);
    }
    .status-bar {
      margin-top: 20px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      font-size: 12px;
      color: var(--text-muted);
      padding-top: 14px;
      border-top: 1px solid rgba(255,255,255,0.06);
    }
    .status-indicator {
      display: inline-block;
      width: 8px;
      height: 8px;
      border-radius: 50%;
      background: #10b981;
      box-shadow: 0 0 8px #10b981;
      margin-right: 6px;
    }
  </style>
</head>
<body>

  <header>
    <h1>SitePulse Android Canlı Test</h1>
    <p>Jetpack Compose Native Uygulaması (emulator-5554)</p>
    <div class="badge">CANLI ETKİLEŞİMLİ EKRAN</div>
  </header>

  <div class="main-container">
    <!-- Interactive Phone Screen -->
    <div class="phone-case">
      <div class="screen-wrapper" id="screenWrapper" onclick="handleScreenClick(event)">
        <img id="screenImg" src="/screen.png" alt="Android Screen">
      </div>
    </div>

    <!-- Interactive Actions Panel -->
    <div class="controls-panel">
      <h2>🎮 Canlı Test Kontrolleri</h2>
      <div class="instructions">
        👉 <strong>Doğrudan Ekrana Dokunabilirsiniz:</strong> Soldaki telefon ekranında istediğiniz herhangi bir yere farenizle tıkladığınızda dokunma olayı anında Android cihazına iletilir.
      </div>

      <div class="action-group">
        <div class="action-group-title">Hızlı Test İşlemleri</div>
        <div class="btn-grid">
          <button class="action-btn primary" onclick="sendTap(540, 800)">💳 Hemen Güvenle Öde</button>
          <button class="action-btn" onclick="sendTap(130, 1140)">🔧 Arıza Bildir</button>
          <button class="action-btn" onclick="sendTap(375, 1140)">⚡ Sayaç Gir</button>
          <button class="action-btn" onclick="sendTap(640, 1140)">🎾 Rezervasyon</button>
          <button class="action-btn" onclick="sendTap(890, 1140)">📞 İletişim</button>
        </div>
      </div>

      <div class="action-group">
        <div class="action-group-title">Navigasyon & Cihaz Düğmeleri</div>
        <div class="btn-grid">
          <button class="action-btn" onclick="sendKey('KEYCODE_BACK')">⬅ Geri Tuşu</button>
          <button class="action-btn" onclick="sendKey('KEYCODE_HOME')">🏠 Ana Ekran</button>
          <button class="action-btn" onclick="sendKey('KEYCODE_APP_SWITCH')">🗂 Son Uygulamalar</button>
          <button class="action-btn" onclick="restartApp()">🚀 SitePulse Yeniden Başlat</button>
        </div>
      </div>

      <div class="status-bar">
        <div><span class="status-indicator"></span>Cihaz: emulator-5554 (Aktif)</div>
        <div id="fpsCounter">Canlı Senkronize</div>
      </div>
    </div>
  </div>

  <script>
    const screenWrapper = document.getElementById('screenWrapper');
    const screenImg = document.getElementById('screenImg');
    let isUpdating = false;

    // Refresh frames continuously
    function refreshScreen() {
      if (isUpdating) return;
      isUpdating = true;
      const nextImg = new Image();
      nextImg.src = '/screen.png?t=' + Date.now();
      nextImg.onload = () => {
        screenImg.src = nextImg.src;
        isUpdating = false;
      };
      nextImg.onerror = () => {
        isUpdating = false;
      };
    }
    setInterval(refreshScreen, 350);

    function handleScreenClick(e) {
      const rect = screenWrapper.getBoundingClientRect();
      const clickX = e.clientX - rect.left;
      const clickY = e.clientY - rect.top;

      // Map from CSS pixels to Android 1080x2400 physical coordinates
      const androidX = Math.round((clickX / rect.width) * 1080);
      const androidY = Math.round((clickY / rect.height) * 2400);

      // Add visual ripple
      const ripple = document.createElement('div');
      ripple.className = 'click-ripple';
      ripple.style.left = clickX + 'px';
      ripple.style.top = clickY + 'px';
      screenWrapper.appendChild(ripple);
      setTimeout(() => ripple.remove(), 400);

      sendTap(androidX, androidY);
    }

    function sendTap(x, y) {
      fetch(`/tap?x=${x}&y=${y}`)
        .then(() => setTimeout(refreshScreen, 150));
    }

    function sendKey(key) {
      fetch(`/key?k=${key}`)
        .then(() => setTimeout(refreshScreen, 200));
    }

    function restartApp() {
      fetch('/restart')
        .then(() => setTimeout(refreshScreen, 500));
    }
  </script>
</body>
</html>
"""

class LiveViewerHandler(BaseHTTPRequestHandler):
    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        params = urllib.parse.parse_qs(parsed.query)

        if path == "/" or path == "/index.html":
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(HTML_TEMPLATE.encode("utf-8"))

        elif path == "/screen.png":
            try:
                proc = subprocess.run([ADB, "exec-out", "screencap", "-p"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=2)
                if proc.returncode == 0:
                    self.send_response(200)
                    self.send_header("Content-Type", "image/png")
                    self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
                    self.end_headers()
                    self.wfile.write(proc.stdout)
                else:
                    self.send_error(500, "ADB Screencap error")
            except Exception as e:
                self.send_error(500, str(e))

        elif path == "/tap":
            x = params.get("x", ["0"])[0]
            y = params.get("y", ["0"])[0]
            subprocess.run([ADB, "shell", "input", "tap", str(x), str(y)], timeout=2)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')

        elif path == "/key":
            k = params.get("k", ["KEYCODE_BACK"])[0]
            subprocess.run([ADB, "shell", "input", "keyevent", str(k)], timeout=2)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')

        elif path == "/restart":
            subprocess.run([ADB, "shell", "am", "start", "-n", "com.sitepulse.app/.MainActivity"], timeout=2)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')

        else:
            self.send_error(404, "Not found")

    def log_message(self, format, *args):
        # Silence standard HTTP access logging to prevent clutter
        pass

if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", PORT), LiveViewerHandler)
    print(f"Interactive Live Android Viewer running at http://localhost:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.server_close()
