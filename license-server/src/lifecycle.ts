interface ClosableApp {
  close(): Promise<unknown>;
  log: {
    info(message: string): void;
    error(error: unknown, message?: string): void;
  };
}

interface DisconnectableDatabase {
  $disconnect(): Promise<unknown>;
}

export function createShutdownHandler(
  app: ClosableApp,
  database: DisconnectableDatabase,
  exit: (code: number) => void = (code) => process.exit(code),
): (signal: string) => Promise<void> {
  let shutdownPromise: Promise<void> | undefined;

  return (signal: string) => {
    if (!shutdownPromise) {
      shutdownPromise = (async () => {
        app.log.info(`Received ${signal}; shutting down`);
        try {
          await app.close();
          await database.$disconnect();
          exit(0);
        } catch (error) {
          app.log.error(error, "Graceful shutdown failed");
          exit(1);
        }
      })();
    }
    return shutdownPromise;
  };
}
