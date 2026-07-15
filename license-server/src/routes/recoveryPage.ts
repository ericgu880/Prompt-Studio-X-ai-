import { randomBytes } from "node:crypto";
import type { FastifyInstance } from "fastify";
import type { AppConfig } from "../config.js";

export async function recoveryPageRoutes(app: FastifyInstance, _config: AppConfig): Promise<void> {
  app.get("/recover", async (_request, reply) => {
    const nonce = randomBytes(16).toString("base64");
    reply.headers({
      "Cache-Control": "no-store, max-age=0",
      Pragma: "no-cache",
      "Referrer-Policy": "no-referrer",
      "X-Robots-Tag": "noindex, nofollow",
      "X-Content-Type-Options": "nosniff",
      "Content-Security-Policy": `default-src 'none'; script-src 'nonce-${nonce}'; style-src 'nonce-${nonce}'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`,
    });
    reply.type("text/html; charset=utf-8");
    return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>找回 PromptStudio 授权</title>
  <style nonce="${nonce}">
    :root{color-scheme:light dark;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
    body{margin:0;min-height:100vh;display:grid;place-items:center;background:#111;color:#f5f5f5}
    main{width:min(440px,calc(100vw - 40px));padding:28px;border:1px solid #333;border-radius:12px;background:#181818}
    h1{margin:0 0 10px;font-size:24px;letter-spacing:0}p{margin:0 0 22px;color:#aaa;line-height:1.6}
    button{width:100%;height:46px;border:0;border-radius:8px;font:600 15px inherit;cursor:pointer}
    #open{background:#fff;color:#111}#copy{margin-top:10px;background:#252525;color:#eee;border:1px solid #383838}
    #status{min-height:20px;margin-top:16px;font-size:13px;color:#aaa}
  </style>
</head>
<body>
  <main>
    <h1>在 PromptStudio 中继续</h1>
    <p>恢复链接将在使用一次或 15 分钟后失效。</p>
    <button id="open" type="button">打开 PromptStudio</button>
    <button id="copy" type="button">复制一次性恢复码</button>
    <div id="status" role="status" aria-live="polite"></div>
  </main>
  <script nonce="${nonce}">
    const params = new URLSearchParams(location.hash.slice(1));
    const token = params.get('token') || '';
    const status = document.getElementById('status');
    const deepLink = 'promptstudio://license/recover#token=' + encodeURIComponent(token);
    const openApp = () => {
      if (!token) { status.textContent = '恢复链接无效，请重新发起找回。'; return; }
      location.href = deepLink;
      status.textContent = '如果 App 没有打开，请使用下方恢复码。';
    };
    document.getElementById('open').addEventListener('click', openApp);
    document.getElementById('copy').addEventListener('click', async () => {
      if (!token) { status.textContent = '恢复链接无效，请重新发起找回。'; return; }
      try { await navigator.clipboard.writeText(token); status.textContent = '恢复码已复制。'; }
      catch { status.textContent = '无法自动复制，请重新打开邮件后重试。'; }
    });
    if (token) setTimeout(openApp, 80);
  </script>
</body>
</html>`;
  });
}
