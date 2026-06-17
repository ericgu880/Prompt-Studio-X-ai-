import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { createHmac, timingSafeEqual } from "node:crypto";
import type { AppConfig } from "../config.js";

type FormBody = Record<string, string>;

function escapeHtml(value: unknown): string {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}

function dateText(value: Date | null | undefined): string {
  return value ? value.toISOString().replace("T", " ").slice(0, 19) : "-";
}

function parseCookies(header: string | undefined): Record<string, string> {
  const cookies: Record<string, string> = {};
  for (const part of header?.split(";") ?? []) {
    const index = part.indexOf("=");
    if (index <= 0) continue;
    cookies[part.slice(0, index).trim()] = decodeURIComponent(part.slice(index + 1).trim());
  }
  return cookies;
}

function signSession(payload: string, secret: string): string {
  return createHmac("sha256", secret).update(payload).digest("base64url");
}

function safeEqual(lhs: string, rhs: string): boolean {
  const left = Buffer.from(lhs);
  const right = Buffer.from(rhs);
  return left.length === right.length && timingSafeEqual(left, right);
}

function sessionSecret(config: AppConfig): string {
  return config.adminSessionSecret || config.adminToken || "promptstudio-admin-dev-session";
}

function createSession(config: AppConfig): string {
  const payload = Buffer.from(JSON.stringify({ exp: Date.now() + 24 * 60 * 60 * 1000 })).toString("base64url");
  return `${payload}.${signSession(payload, sessionSecret(config))}`;
}

function verifySession(config: AppConfig, value: string | undefined): boolean {
  if (!value) return false;
  const [payload, signature] = value.split(".");
  if (!payload || !signature || !safeEqual(signature, signSession(payload, sessionSecret(config)))) return false;
  try {
    const parsed = JSON.parse(Buffer.from(payload, "base64url").toString("utf8")) as { exp?: number };
    return typeof parsed.exp === "number" && parsed.exp > Date.now();
  } catch {
    return false;
  }
}

function isAuthenticated(request: FastifyRequest, config: AppConfig): boolean {
  return verifySession(config, parseCookies(request.headers.cookie).ps_admin);
}

function setSessionCookie(reply: FastifyReply, config: AppConfig): void {
  const secure = config.nodeEnv === "production" ? "; Secure" : "";
  reply.header(
    "Set-Cookie",
    `ps_admin=${encodeURIComponent(createSession(config))}; Path=/admin; Max-Age=86400; HttpOnly; SameSite=Lax${secure}`
  );
}

function clearSessionCookie(reply: FastifyReply): void {
  reply.header("Set-Cookie", "ps_admin=; Path=/admin; Max-Age=0; HttpOnly; SameSite=Lax");
}

function formBody(request: FastifyRequest): FormBody {
  return (request.body && typeof request.body === "object" ? request.body : {}) as FormBody;
}

function redirect(reply: FastifyReply, location: string): void {
  reply.code(303).header("Location", location).send();
}

function page(title: string, body: string, authenticated = true): string {
  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${escapeHtml(title)} - PromptStudio Admin</title>
  <style>
    :root { color-scheme: dark; --bg:#101215; --panel:#181b20; --line:#2a2f37; --text:#f2f3f5; --muted:#9aa3ad; --accent:#7cc7ff; --danger:#ff6b6b; }
    * { box-sizing: border-box; }
    body { margin:0; background:var(--bg); color:var(--text); font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
    a { color:var(--accent); text-decoration:none; }
    header { height:56px; display:flex; align-items:center; justify-content:space-between; padding:0 24px; border-bottom:1px solid var(--line); background:#12151a; }
    main { max-width:1180px; margin:0 auto; padding:24px; }
    h1 { font-size:22px; margin:0 0 18px; }
    h2 { font-size:15px; margin:0 0 12px; }
    .grid { display:grid; grid-template-columns: 360px 1fr; gap:18px; align-items:start; }
    .panel { background:var(--panel); border:1px solid var(--line); border-radius:8px; padding:16px; }
    .row { display:flex; gap:10px; align-items:center; flex-wrap:wrap; }
    .muted { color:var(--muted); }
    label { display:block; color:var(--muted); font-size:12px; margin:10px 0 5px; }
    input, select { width:100%; height:36px; border:1px solid var(--line); border-radius:7px; background:#111419; color:var(--text); padding:0 10px; }
    button, .button { height:34px; border:1px solid var(--line); border-radius:999px; background:#232832; color:var(--text); padding:0 14px; cursor:pointer; display:inline-flex; align-items:center; }
    button.primary, .button.primary { background:var(--accent); color:#071017; border-color:var(--accent); font-weight:600; }
    button.danger { color:#fff; background:#4d2024; border-color:#693036; }
    table { width:100%; border-collapse:collapse; }
    th, td { text-align:left; padding:10px; border-top:1px solid var(--line); vertical-align:top; }
    th { color:var(--muted); font-size:12px; font-weight:500; }
    code { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; background:#0e1116; border:1px solid var(--line); border-radius:6px; padding:2px 5px; }
    .notice { border-color:#36516a; background:#132232; }
    .code-box { font:18px ui-monospace,SFMono-Regular,Menlo,monospace; padding:12px; background:#0e1116; border:1px solid var(--line); border-radius:8px; user-select:all; }
  </style>
</head>
<body>
  <header>
    <strong>PromptStudio License Admin</strong>
    ${authenticated ? `<form method="post" action="/admin/logout"><button>退出</button></form>` : ""}
  </header>
  <main>${body}</main>
</body>
</html>`;
}

function disabledPage(): string {
  return page("Admin disabled", `
    <section class="panel">
      <h1>后台未启用</h1>
      <p class="muted">请先在 license-server 的 .env 中设置 <code>ADMIN_TOKEN</code>。</p>
    </section>
  `, false);
}

function loginPage(error = ""): string {
  return page("Login", `
    <section class="panel" style="max-width:420px;margin:60px auto;">
      <h1>登录后台</h1>
      ${error ? `<p class="muted">${escapeHtml(error)}</p>` : ""}
      <form method="post" action="/admin/login">
        <label>Admin Token</label>
        <input name="token" type="password" autocomplete="current-password" autofocus />
        <div class="row" style="margin-top:16px;"><button class="primary" type="submit">登录</button></div>
      </form>
    </section>
  `, false);
}

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function adminErrorNotice(title: string, error: unknown): string {
  return `
    <div class="panel notice" style="margin-bottom:16px;">
      <h2>${escapeHtml(title)}</h2>
      <p class="muted">${escapeHtml(errorText(error))}</p>
      <p class="muted">如果要生成真实激活码，请先启动 PostgreSQL 并执行 <code>npm run prisma:migrate</code>。</p>
    </div>
  `;
}

export async function adminRoutes(app: FastifyInstance, config: AppConfig): Promise<void> {
  app.addContentTypeParser("application/x-www-form-urlencoded", { parseAs: "string" }, (_request, body, done) => {
    done(null, Object.fromEntries(new URLSearchParams(String(body))));
  });

  app.get("/admin/login", async (_request, reply) => {
    if (!config.adminToken) return reply.type("text/html").send(disabledPage());
    return reply.type("text/html").send(loginPage());
  });

  app.post("/admin/login", async (request, reply) => {
    if (!config.adminToken) return reply.type("text/html").send(disabledPage());
    const token = formBody(request).token ?? "";
    if (!safeEqual(token, config.adminToken)) {
      return reply.code(401).type("text/html").send(loginPage("Token 不正确。"));
    }
    setSessionCookie(reply, config);
    redirect(reply, "/admin");
  });

  app.post("/admin/logout", async (_request, reply) => {
    clearSessionCookie(reply);
    redirect(reply, "/admin/login");
  });

  app.addHook("preHandler", async (request, reply) => {
    if (!request.url.startsWith("/admin") || request.url === "/admin/login") return;
    if (!config.adminToken) {
      reply.type("text/html").send(disabledPage());
      return reply;
    }
    if (!isAuthenticated(request, config)) {
      redirect(reply, "/admin/login");
      return reply;
    }
  });

  app.get("/admin", async (request, reply) => {
    const email = typeof (request.query as { email?: string }).email === "string"
      ? (request.query as { email: string }).email.trim()
      : "";
    let listError: unknown;
    const licenses = await app.licenseServices.licenses.listLicenses(email || undefined).catch((error: unknown) => {
      listError = error;
      return [];
    });
    const rows = licenses.map((license) => `
      <tr>
        <td><a href="/admin/licenses/${escapeHtml(license.id)}"><code>${escapeHtml(license.id)}</code></a></td>
        <td>${escapeHtml(license.email)}</td>
        <td>${escapeHtml(license.code)}</td>
        <td>${escapeHtml(license.plan)}</td>
        <td>${escapeHtml(license.status)}</td>
        <td>${license.activeDevices}/${license.seats}</td>
        <td>${dateText(license.createdAt)}</td>
      </tr>
    `).join("");
    return reply.type("text/html").send(page("Licenses", `
      <h1>授权后台</h1>
      ${listError ? adminErrorNotice("数据库未连接，当前为界面预览", listError) : ""}
      <div class="grid">
        <section class="panel">
          <h2>创建授权</h2>
          <form method="post" action="/admin/licenses">
            <label>购买邮箱</label><input name="email" type="email" required />
            <label>方案</label><input name="plan" value="pro_lifetime" required />
            <label>设备数</label><input name="seats" type="number" min="1" max="99" value="2" required />
            <label>订单来源</label><input name="provider" placeholder="stripe / paddle / manual" />
            <label>订单 ID</label><input name="orderId" />
            <div class="row" style="margin-top:16px;"><button class="primary" type="submit">生成激活码</button></div>
          </form>
        </section>
        <section class="panel">
          <div class="row" style="justify-content:space-between;margin-bottom:12px;">
            <h2>授权列表</h2>
            <form class="row" method="get" action="/admin">
              <input style="width:240px;" name="email" type="email" placeholder="按邮箱搜索" value="${escapeHtml(email)}" />
              <button type="submit">搜索</button>
            </form>
          </div>
          <table>
            <thead><tr><th>ID</th><th>邮箱</th><th>激活码</th><th>方案</th><th>状态</th><th>设备</th><th>创建时间</th></tr></thead>
            <tbody>${listError ? `<tr><td colspan="7" class="muted">数据库连接后会显示真实授权列表。</td></tr>` : rows || `<tr><td colspan="7" class="muted">暂无授权</td></tr>`}</tbody>
          </table>
        </section>
      </div>
    `));
  });

  app.post("/admin/licenses", async (request, reply) => {
    const body = formBody(request);
    const result = await app.licenseServices.licenses.createLicense({
      email: body.email,
      plan: body.plan || "pro_lifetime",
      seats: Number(body.seats || "2"),
      orderProvider: body.provider || undefined,
      orderId: body.orderId || undefined
    }).catch((error: unknown) => ({ error }));
    if ("error" in result) {
      return reply.code(503).type("text/html").send(page("Database unavailable", `
        <p><a href="/admin">← 返回后台</a></p>
        ${adminErrorNotice("无法生成激活码：数据库未连接", result.error)}
      `));
    }
    return reply.type("text/html").send(page("License created", `
      <section class="panel notice">
        <h1>激活码已生成</h1>
        <p class="muted">这个明文激活码只显示这一次。发送给用户后请不要再存明文。</p>
        <div class="code-box">${escapeHtml(result.licenseCode)}</div>
        <p>邮箱：${escapeHtml(result.emailMasked)} · 方案：${escapeHtml(result.plan)} · 设备数：${result.seats}</p>
        <div class="row"><a class="button primary" href="/admin/licenses/${escapeHtml(result.id)}">查看授权</a><a class="button" href="/admin">返回列表</a></div>
      </section>
    `));
  });

  app.get("/admin/licenses/:id", async (request, reply) => {
    const id = (request.params as { id: string }).id;
    const license = await app.licenseServices.licenses.getLicenseDetail(id);
    if (!license) return reply.code(404).type("text/html").send(page("Not found", `<section class="panel"><h1>授权不存在</h1></section>`));
    const devices = license.devices.map((device) => `
      <tr>
        <td><code>${escapeHtml(device.id)}</code><br><span class="muted">${escapeHtml(device.label)}</span></td>
        <td>${escapeHtml(device.status)}</td>
        <td>${escapeHtml(device.appVersion || "-")}<br><span class="muted">${escapeHtml(device.osVersion || "-")}</span></td>
        <td>${dateText(device.activatedAt)}<br><span class="muted">Last seen: ${dateText(device.lastSeenAt)}</span></td>
        <td>
          ${device.status === "active" ? `<form method="post" action="/admin/activations/${escapeHtml(device.id)}/deactivate">
            <input type="hidden" name="licenseId" value="${escapeHtml(license.id)}" />
            <input type="hidden" name="reason" value="admin_portal" />
            <button class="danger" type="submit">停用</button>
          </form>` : `<span class="muted">${escapeHtml(device.deactivatedReason || "-")}</span>`}
        </td>
      </tr>
    `).join("");
    const events = license.events.map((event) => `
      <tr><td>${dateText(event.createdAt)}</td><td>${escapeHtml(event.eventType)}</td><td>${escapeHtml(event.eventSource)}</td><td>${escapeHtml(event.activationId || "-")}</td></tr>
    `).join("");
    return reply.type("text/html").send(page("License detail", `
      <p><a href="/admin">← 返回列表</a></p>
      <section class="panel">
        <h1>${escapeHtml(license.email)} · ${escapeHtml(license.plan)}</h1>
        <div class="row">
          <span>状态：<code>${escapeHtml(license.status)}</code></span>
          <span>激活码：<code>${escapeHtml(license.code)}</code></span>
          <span>设备：<code>${license.devices.filter((d) => d.status === "active").length}/${license.seats}</code></span>
          <span>创建：${dateText(license.createdAt)}</span>
        </div>
        <div class="row" style="margin-top:16px;">
          <form class="row" method="post" action="/admin/licenses/${escapeHtml(license.id)}/add-seats">
            <input style="width:90px;" name="seats" type="number" min="1" value="1" />
            <button type="submit">增加 seats</button>
          </form>
          <form method="post" action="/admin/licenses/${escapeHtml(license.id)}/rotate-code">
            <input type="hidden" name="reason" value="admin_portal" />
            <button type="submit">轮换激活码</button>
          </form>
          <form method="post" action="/admin/licenses/${escapeHtml(license.id)}/revoke">
            <input type="hidden" name="reason" value="admin_portal" />
            <button class="danger" type="submit">撤销授权</button>
          </form>
        </div>
      </section>
      <section class="panel" style="margin-top:18px;">
        <h2>设备</h2>
        <table><thead><tr><th>设备</th><th>状态</th><th>版本</th><th>时间</th><th>操作</th></tr></thead><tbody>${devices || `<tr><td colspan="5" class="muted">暂无设备</td></tr>`}</tbody></table>
      </section>
      <section class="panel" style="margin-top:18px;">
        <h2>审计事件</h2>
        <table><thead><tr><th>时间</th><th>事件</th><th>来源</th><th>设备</th></tr></thead><tbody>${events || `<tr><td colspan="4" class="muted">暂无事件</td></tr>`}</tbody></table>
      </section>
    `));
  });

  app.post("/admin/licenses/:id/add-seats", async (request, reply) => {
    const id = (request.params as { id: string }).id;
    await app.licenseServices.licenses.addSeats(id, Number(formBody(request).seats || "1"));
    redirect(reply, `/admin/licenses/${encodeURIComponent(id)}`);
  });

  app.post("/admin/licenses/:id/revoke", async (request, reply) => {
    const id = (request.params as { id: string }).id;
    await app.licenseServices.licenses.revokeLicense(id, formBody(request).reason || "admin_portal");
    redirect(reply, `/admin/licenses/${encodeURIComponent(id)}`);
  });

  app.post("/admin/licenses/:id/rotate-code", async (request, reply) => {
    const id = (request.params as { id: string }).id;
    const code = await app.licenseServices.licenses.rotateCode(id, formBody(request).reason || "admin_portal");
    return reply.type("text/html").send(page("License code rotated", `
      <section class="panel notice">
        <h1>新激活码</h1>
        <p class="muted">这个明文激活码只显示这一次。</p>
        <div class="code-box">${escapeHtml(code)}</div>
        <div class="row" style="margin-top:16px;"><a class="button primary" href="/admin/licenses/${escapeHtml(id)}">返回授权详情</a></div>
      </section>
    `));
  });

  app.post("/admin/activations/:id/deactivate", async (request, reply) => {
    const activationId = (request.params as { id: string }).id;
    const body = formBody(request);
    await app.licenseServices.licenses.deactivateDevice(activationId, body.reason || "admin_portal");
    redirect(reply, `/admin/licenses/${encodeURIComponent(body.licenseId || "")}`);
  });
}
