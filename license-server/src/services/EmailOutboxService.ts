import type { PrismaClient } from "@prisma/client";
import type { AppConfig } from "../config.js";

export interface PurchaseEmailPayload {
  version: 1;
  kind: "purchase";
  to: string;
  emailMasked: string;
  licenseCode: string;
  plan: "pro_lifetime";
  seats: number;
  majorVersion: number;
  updatesUntil: string;
}

export interface RecoveryEmailPayload {
  version: 1;
  kind: "recovery";
  to: string;
  emailMasked: string;
  recoveryURL: string;
  recoveryToken: string;
  expiresAt: string;
}

export type LicenseEmailPayload = PurchaseEmailPayload | RecoveryEmailPayload;

export interface RenderedEmail {
  to: string;
  subject: string;
  html: string;
  text: string;
}

function escapeHTML(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

export function renderLicenseEmail(payload: LicenseEmailPayload, config: AppConfig): RenderedEmail {
  if (payload.kind === "purchase") {
    const code = escapeHTML(payload.licenseCode);
    const supportURL = escapeHTML(config.commercial.supportURL);
    return {
      to: payload.to,
      subject: "您的 PromptStudio Pro 激活码",
      text: [
        "PromptStudio Pro 已准备就绪。",
        `激活码：${payload.licenseCode}`,
        `设备席位：${payload.seats} 台`,
        `更新权益至：${payload.updatesUntil.slice(0, 10)}`,
        `支持：${config.commercial.supportURL}`,
      ].join("\n\n"),
      html: `<main style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;max-width:560px;margin:0 auto;color:#171717">
        <h1 style="font-size:24px">PromptStudio Pro 已准备就绪</h1>
        <p>感谢购买永久授权。可在 ${payload.seats} 台设备上使用，购买版本永久有效。</p>
        <div style="margin:24px 0;padding:18px;border:1px solid #d9d9d9;border-radius:8px;background:#f7f7f7">
          <div style="font-size:13px;color:#666">激活码</div>
          <div style="margin-top:8px;font:600 20px ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:.04em">${code}</div>
        </div>
        <p style="color:#666">更新权益至 ${escapeHTML(payload.updatesUntil.slice(0, 10))}。权益到期不影响已购买版本和本地资料。</p>
        <p><a href="${supportURL}">需要帮助</a></p>
      </main>`,
    };
  }

  const recoveryURL = escapeHTML(payload.recoveryURL);
  const supportURL = escapeHTML(config.commercial.supportURL);
  return {
    to: payload.to,
    subject: "找回您的 PromptStudio 授权",
    text: [
      "请在 15 分钟内打开以下链接找回 PromptStudio 授权：",
      payload.recoveryURL,
      `一次性恢复码：${payload.recoveryToken}`,
      "如果不是您发起的请求，可以忽略此邮件。",
    ].join("\n\n"),
    html: `<main style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;max-width:560px;margin:0 auto;color:#171717">
      <h1 style="font-size:24px">找回 PromptStudio 授权</h1>
      <p>此链接 15 分钟内有效，成功使用一次后立即失效。</p>
      <p style="margin:28px 0"><a href="${recoveryURL}" style="display:inline-block;padding:12px 18px;border-radius:8px;background:#171717;color:#fff;text-decoration:none">在 PromptStudio 中继续</a></p>
      <p style="font-size:13px;color:#666">无法打开 App？恢复页可复制一次性恢复码。</p>
      <p style="font-size:13px;color:#666">若非本人操作，请忽略此邮件。<a href="${supportURL}">联系支持</a></p>
    </main>`,
  };
}

export class EmailOutboxService {
  constructor(
    private readonly prisma: PrismaClient,
    private readonly config: AppConfig,
  ) {}

  async recordProviderEvent(input: { type: string; providerMessageId: string }): Promise<boolean> {
    const state = this.providerState(input.type);
    if (!state) return false;
    const result = await this.prisma.emailOutbox.updateMany({
      where: { providerMessageId: input.providerMessageId },
      data: {
        status: state.status,
        ...(state.status === "delivered" ? { deliveredAt: new Date() } : {}),
        ...(state.errorCode ? { lastErrorCode: state.errorCode } : {}),
      },
    });
    return result.count > 0;
  }

  private providerState(type: string): { status: "accepted" | "delivered" | "delayed" | "bounced" | "failed"; errorCode?: string } | null {
    if (type === "email.sent") return { status: "accepted" };
    if (type === "email.delivered") return { status: "delivered" };
    if (type === "email.delivery_delayed") return { status: "delayed" };
    if (type === "email.bounced") return { status: "bounced", errorCode: "EMAIL_BOUNCED" };
    if (type === "email.failed") return { status: "failed", errorCode: "EMAIL_FAILED" };
    return null;
  }
}
