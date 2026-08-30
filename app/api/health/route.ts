import { NextResponse } from "next/server";
import { prisma } from "@/lib/db/client";
import { getDMQueue, getRedisConnection } from "@/lib/queue/client";
import { getWorkerHealth } from "@/lib/ops/worker-health";

export const runtime = "nodejs";
// Health must reflect live state (worker heartbeat, queue depth), never a
// cached response, or it reports stale worker start times.
export const dynamic = "force-dynamic";

type CheckStatus = "ok" | "error";

interface HealthCheck {
  status: CheckStatus;
  detail?: string;
}

const exposeDiagnosticDetails = process.env.NODE_ENV !== "production";

function failedCheck(error: unknown, fallback: string): HealthCheck {
  return {
    status: "error",
    ...(exposeDiagnosticDetails
      ? { detail: error instanceof Error ? error.message : fallback }
      : {}),
  };
}

async function checkDatabase(): Promise<HealthCheck> {
  try {
    await prisma.$queryRaw`SELECT 1`;
    return { status: "ok" };
  } catch (error) {
    return failedCheck(error, "Database check failed");
  }
}

async function checkRedis(): Promise<HealthCheck> {
  try {
    const pong = await getRedisConnection().ping();
    return { status: pong === "PONG" ? "ok" : "error", detail: pong };
  } catch (error) {
    return failedCheck(error, "Redis check failed");
  }
}

async function checkQueue(): Promise<HealthCheck & { counts?: unknown }> {
  try {
    const counts = await getDMQueue().getJobCounts(
      "waiting",
      "active",
      "delayed",
      "failed"
    );
    return { status: "ok", counts };
  } catch (error) {
    return failedCheck(error, "Queue check failed");
  }
}

export async function GET() {
  const [database, redis, queue, worker] = await Promise.all([
    checkDatabase(),
    checkRedis(),
    checkQueue(),
    getWorkerHealth().catch((error) => ({
      healthy: false,
      heartbeat: null,
      ageMs: null,
      error: error instanceof Error ? error.message : "Worker check failed",
    })),
  ]);

  const healthy =
    database.status === "ok" &&
    redis.status === "ok" &&
    queue.status === "ok" &&
    worker.healthy;

  const workerCheck = exposeDiagnosticDetails
    ? worker
    : {
        healthy: worker.healthy,
        ageMs: worker.ageMs,
      };

  return NextResponse.json(
    {
      status: healthy ? "ok" : "degraded",
      checks: {
        database,
        redis,
        queue,
        worker: workerCheck,
      },
    },
    { status: healthy ? 200 : 503 }
  );
}
