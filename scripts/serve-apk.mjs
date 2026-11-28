// APK 다운로드 서버: Tailscale 주소(100.x)에만 열어 tailnet 기기에서만 받을 수 있게 한다.
//   node scripts/serve-apk.mjs [포트=8787] [주소=tailscale ip -4]
// 요청마다 build/PocketCardDeckViewer.apk 를 새로 읽으므로 다시 빌드하면 같은 링크로 최신 APK 가 받아진다.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const apk = path.join(root, 'build', 'PocketCardDeckViewer.apk');
const port = Number(process.argv[2] ?? 8787);

function tailscaleIp() {
  const exe = process.platform === 'win32' ? 'C:\\Program Files\\Tailscale\\tailscale.exe' : 'tailscale';
  return execFileSync(exe, ['ip', '-4'], { encoding: 'utf8' }).trim().split(/\s+/)[0];
}
const host = process.argv[3] ?? tailscaleIp();
if (!host.startsWith('100.')) throw new Error(`Tailscale 주소가 아님: ${host}`);

const page = (st) => `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>PocketCard APK</title>
<body style="font-family:sans-serif;padding:24px;line-height:1.6">
<h2>PocketCard 덱 뷰어</h2>
<p>빌드 시각: ${st.mtime.toLocaleString('ko-KR')}<br>크기: ${(st.size / 1048576).toFixed(1)} MB</p>
<p><a href="/PocketCard.apk" style="display:inline-block;padding:14px 22px;background:#1b6b5a;color:#fff;border-radius:12px;text-decoration:none;font-size:20px">APK 받기</a></p>
</body>`;

http.createServer((req, res) => {
  const url = (req.url ?? '/').split('?')[0];
  let st;
  try { st = fs.statSync(apk); } catch { res.writeHead(404); res.end('APK 없음 (build-app 먼저)'); return; }
  if (url === '/' || url === '/index.html') {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
    res.end(page(st));
  } else if (url === '/PocketCard.apk') {
    res.writeHead(200, {
      'content-type': 'application/vnd.android.package-archive',
      'content-length': st.size,
      'content-disposition': 'attachment; filename="PocketCard.apk"',
      'cache-control': 'no-store',
    });
    fs.createReadStream(apk).pipe(res);
  } else {
    res.writeHead(404); res.end();
  }
  console.log(new Date().toISOString(), req.socket.remoteAddress, req.method, url);
}).listen(port, host, () => console.log(`APK 서버: http://${host}:${port}/`));
