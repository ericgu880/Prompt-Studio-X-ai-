import type { FastifyInstance } from "fastify";
import type { PrismaClient } from "@prisma/client";

const REQUIRED_MIGRATION = "0004_commerce_order_reconciliation";

export async function healthRoutes(app: FastifyInstance, prisma: PrismaClient): Promise<void> {
  app.get("/health", async () => ({ ok: true }));
  app.get("/ready", async (_request, reply) => {
    try {
      await prisma.$queryRawUnsafe("SELECT 1 AS ready");
      const migrations = await prisma.$queryRawUnsafe<Array<{ migrationApplied: boolean }>>(
        `SELECT EXISTS (
          SELECT 1
          FROM "_prisma_migrations"
          WHERE "migration_name" = $1
            AND "finished_at" IS NOT NULL
            AND "rolled_back_at" IS NULL
        ) AS "migrationApplied"`,
        REQUIRED_MIGRATION,
      );
      if (migrations[0]?.migrationApplied !== true) {
        throw new Error("Required database migration is not applied");
      }
      return { ok: true };
    } catch {
      return reply.code(503).send({
        ok: false,
        error: { code: "DEPENDENCY_UNAVAILABLE" },
      });
    }
  });
}
