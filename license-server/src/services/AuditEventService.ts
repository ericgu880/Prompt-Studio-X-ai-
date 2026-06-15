import type { Prisma, PrismaClient } from "@prisma/client";

export class AuditEventService {
  constructor(private readonly prisma: PrismaClient) {}

  async record(input: {
    licenseId?: string | null;
    activationId?: string | null;
    eventType: string;
    eventSource?: "api" | "cli" | "system";
    emailHash?: string | null;
    codePrefix?: string | null;
    ipHash?: string | null;
    userAgentHash?: string | null;
    metadataJson?: Prisma.InputJsonValue;
  }): Promise<void> {
    await this.prisma.licenseEvent.create({
      data: {
        licenseId: input.licenseId ?? null,
        activationId: input.activationId ?? null,
        eventType: input.eventType,
        eventSource: input.eventSource ?? "api",
        emailHash: input.emailHash ?? null,
        codePrefix: input.codePrefix ?? null,
        ipHash: input.ipHash ?? null,
        userAgentHash: input.userAgentHash ?? null,
        metadataJson: input.metadataJson ?? undefined
      }
    });
  }
}
