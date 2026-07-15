import type { AdminSession, AdminUser, Prisma, PrismaClient } from "@prisma/client";
import { compare, hash } from "bcryptjs";
import { randomBytes, timingSafeEqual } from "node:crypto";
import type { AppConfig } from "../config.js";
import { hmacSha256Base64URL, hmacSha256Hex, sha256Hex } from "../crypto/hash.js";

export class AdminAPIError extends Error {
  constructor(
    public readonly code: string,
    public readonly statusCode: number,
    message: string,
    public readonly data?: unknown
  ) {
    super(message);
  }
}

export interface AdminContext {
  user: Pick<AdminUser, "id" | "email" | "role">;
  session: AdminSession;
  csrfToken: string;
}

export class AdminAuthService {
  static readonly cookieName = "ps_admin_session";
  private static readonly absoluteTtlMs = 12 * 60 * 60 * 1000;
  private static readonly idleTtlMs = 30 * 60 * 1000;
  private static readonly lastSeenWriteMs = 5 * 60 * 1000;

  constructor(
    private readonly prisma: PrismaClient,
    private readonly config: AppConfig
  ) {}

  normalizeEmail(email: string): string {
    return email.trim().toLowerCase();
  }

  async hashPassword(password: string): Promise<string> {
    return hash(password, 12);
  }

  async verifyPassword(password: string, passwordHash: string): Promise<boolean> {
    return compare(password, passwordHash);
  }

  tokenHash(token: string): string {
    return hmacSha256Hex(this.config.adminSessionSecret ?? this.config.adminHmacSecret, token);
  }

  csrfToken(session: Pick<AdminSession, "id" | "csrfVersion">): string {
    return hmacSha256Base64URL(this.config.adminCsrfSecret, `${session.id}:${session.csrfVersion}`);
  }

  safeEqual(left: string, right: string): boolean {
    const lhs = Buffer.from(left);
    const rhs = Buffer.from(right);
    return lhs.length === rhs.length && timingSafeEqual(lhs, rhs);
  }

  requestHmac(value: string | undefined): string | undefined {
    return value ? hmacSha256Hex(this.config.adminHmacSecret, value) : undefined;
  }

  requestHash(value: unknown): string {
    return sha256Hex(JSON.stringify(value));
  }

  async createUser(email: string, password: string): Promise<Pick<AdminUser, "id" | "email" | "role">> {
    const normalizedEmail = this.normalizeEmail(email);
    const passwordHash = await this.hashPassword(password);
    const user = await this.prisma.adminUser.create({
      data: { email: normalizedEmail, passwordHash }
    });
    return { id: user.id, email: user.email, role: user.role };
  }

  async setPassword(email: string, password: string): Promise<void> {
    const normalizedEmail = this.normalizeEmail(email);
    const passwordHash = await this.hashPassword(password);
    await this.prisma.$transaction(async (tx) => {
      const user = await tx.adminUser.update({
        where: { email: normalizedEmail },
        data: { passwordHash, passwordChangedAt: new Date() }
      });
      await tx.adminSession.updateMany({
        where: { adminUserId: user.id, revokedAt: null },
        data: { revokedAt: new Date() }
      });
      await tx.adminAuditLog.create({
        data: {
          adminUserId: user.id,
          actorSnapshot: user.email,
          action: "admin_password_changed",
          targetType: "admin_user",
          targetId: user.id,
          result: "success"
        }
      });
    });
  }

  async disableUser(email: string): Promise<void> {
    const normalizedEmail = this.normalizeEmail(email);
    await this.prisma.$transaction(async (tx) => {
      const user = await tx.adminUser.update({
        where: { email: normalizedEmail },
        data: { disabledAt: new Date() }
      });
      await tx.adminSession.updateMany({
        where: { adminUserId: user.id, revokedAt: null },
        data: { revokedAt: new Date() }
      });
      await tx.adminAuditLog.create({
        data: {
          adminUserId: user.id,
          actorSnapshot: user.email,
          action: "admin_user_disabled",
          targetType: "admin_user",
          targetId: user.id,
          result: "success"
        }
      });
    });
  }

  async revokeSessions(email: string): Promise<void> {
    const normalizedEmail = this.normalizeEmail(email);
    await this.prisma.$transaction(async (tx) => {
      const user = await tx.adminUser.findUniqueOrThrow({ where: { email: normalizedEmail } });
      await tx.adminSession.updateMany({
        where: { adminUserId: user.id, revokedAt: null },
        data: { revokedAt: new Date() }
      });
      await tx.adminAuditLog.create({
        data: {
          adminUserId: user.id,
          actorSnapshot: user.email,
          action: "admin_sessions_revoked",
          targetType: "admin_user",
          targetId: user.id,
          result: "success"
        }
      });
    });
  }

  async login(input: {
    email: string;
    password: string;
    requestId: string;
    ipHmac?: string;
    userAgentHmac?: string;
  }): Promise<{ token: string; context: AdminContext }> {
    const email = this.normalizeEmail(input.email);
    const user = await this.prisma.adminUser.findUnique({ where: { email } });
    if (!user || user.disabledAt || !(await this.verifyPassword(input.password, user.passwordHash))) {
      await this.recordLoginFailure(email, input.requestId, input.ipHmac, input.userAgentHmac);
      throw new AdminAPIError("INVALID_CREDENTIALS", 401, "邮箱或密码错误。");
    }

    const token = randomBytes(32).toString("base64url");
    const expiresAt = new Date(Date.now() + AdminAuthService.absoluteTtlMs);
    const session = await this.prisma.$transaction(async (tx) => {
      const created = await tx.adminSession.create({
        data: {
          adminUserId: user.id,
          tokenHash: this.tokenHash(token),
          expiresAt,
          lastSeenAt: new Date()
        }
      });
      await tx.adminAuditLog.create({
        data: {
          adminUserId: user.id,
          actorSnapshot: user.email,
          action: "admin_login_success",
          targetType: "admin_user",
          targetId: user.id,
          result: "success",
          requestId: input.requestId,
          ipHmac: input.ipHmac,
          userAgentHmac: input.userAgentHmac
        }
      });
      return created;
    });

    return {
      token,
      context: {
        user: { id: user.id, email: user.email, role: user.role },
        session,
        csrfToken: this.csrfToken(session)
      }
    };
  }

  async authenticate(token: string | undefined): Promise<AdminContext | null> {
    if (!token) return null;
    const session = await this.prisma.adminSession.findUnique({
      where: { tokenHash: this.tokenHash(token) },
      include: { adminUser: true }
    });
    if (!session || session.revokedAt || session.expiresAt <= new Date() || session.adminUser.disabledAt) {
      return null;
    }
    const idleCutoff = new Date(Date.now() - AdminAuthService.idleTtlMs);
    if (session.lastSeenAt && session.lastSeenAt < idleCutoff) {
      return null;
    }
    const writeCutoff = new Date(Date.now() - AdminAuthService.lastSeenWriteMs);
    if (!session.lastSeenAt || session.lastSeenAt < writeCutoff) {
      await this.prisma.adminSession.update({
        where: { id: session.id },
        data: { lastSeenAt: new Date() }
      }).catch(() => undefined);
    }
    return {
      user: { id: session.adminUser.id, email: session.adminUser.email, role: session.adminUser.role },
      session,
      csrfToken: this.csrfToken(session)
    };
  }

  async logout(sessionId: string): Promise<void> {
    await this.prisma.adminSession.update({
      where: { id: sessionId },
      data: { revokedAt: new Date() }
    });
  }

  async recordAudit(input: {
    tx?: Prisma.TransactionClient;
    adminUserId?: string;
    actorSnapshot?: string;
    action: string;
    targetType?: string;
    targetId?: string;
    result: string;
    reason?: string;
    requestId?: string;
    ipHmac?: string;
    userAgentHmac?: string;
    metadataJson?: Prisma.InputJsonValue;
  }): Promise<void> {
    const client = input.tx ?? this.prisma;
    await client.adminAuditLog.create({
      data: {
        adminUserId: input.adminUserId,
        actorSnapshot: input.actorSnapshot,
        action: input.action,
        targetType: input.targetType,
        targetId: input.targetId,
        result: input.result,
        reason: input.reason,
        requestId: input.requestId,
        ipHmac: input.ipHmac,
        userAgentHmac: input.userAgentHmac,
        metadataJson: input.metadataJson
      }
    });
  }

  private async recordLoginFailure(email: string, requestId: string, ipHmac?: string, userAgentHmac?: string): Promise<void> {
    await this.prisma.adminAuditLog.create({
      data: {
        actorSnapshot: email,
        action: "admin_login_failed",
        targetType: "admin_user",
        result: "failed",
        reason: "invalid_credentials",
        requestId,
        ipHmac,
        userAgentHmac
      }
    }).catch(() => undefined);
  }
}
