# OpenReply — self-hosted Docker image
#
# Two runtime processes ship from this image:
#   - web:    `npm run start`  → next start (needs .next + node_modules)
#   - worker: `npm run worker` → tsx worker/dm-worker.ts (runs RAW TypeScript,
#             not a bundled output — needs the generated Prisma client, the
#             full source tree under lib/ and worker/, and tsconfig.json for
#             the `@/*` path alias tsx resolves at runtime)
#   - cron:   `sh scripts/cron.sh` → the scheduler for /api/cron, which nothing
#             runs off Vercel (see docs/deploy-dokploy.md). It needs scripts/
#             in the image and wget on PATH; node:22-bookworm-slim ships neither.
#
# next.config.ts does not set `output: "standalone"`, so `next start` already
# requires the full node_modules tree at runtime — there is no slimmer
# standalone bundle to fall back to here. Given that, this Dockerfile does
# NOT try to strip node_modules/tsconfig.json/source files out of the final
# stage: doing so is exactly what breaks the worker (MODULE_NOT_FOUND on
# `@/lib/...` imports, because tsx has no tsconfig to resolve the alias
# against, and no app/generated/prisma to import from).

FROM node:22-bookworm-slim AS build
WORKDIR /app

# Prisma detects the OpenSSL ABI while generating its client. Install OpenSSL
# in the build stage so it does not silently generate against the wrong ABI.
RUN apt-get update \
 && apt-get install -y --no-install-recommends openssl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY package.json package-lock.json ./
RUN npm ci

COPY . .
# `npm run build` = `prisma generate && next build` (see package.json) —
# generates app/generated/prisma AND compiles .next/ in one step.
RUN npm run build

FROM node:22-bookworm-slim AS runner
WORKDIR /app
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1

# scripts/cron.sh calls the /api/cron routes with wget, which the slim Node
# image does not include.
RUN apt-get update \
 && apt-get install -y --no-install-recommends wget ca-certificates openssl \
 && rm -rf /var/lib/apt/lists/*

COPY --chown=node:node --from=build /app/node_modules ./node_modules
COPY --chown=node:node --from=build /app/.next ./.next
COPY --chown=node:node --from=build /app/app/generated ./app/generated
COPY --chown=node:node --from=build /app/public ./public
COPY --chown=node:node --from=build /app/lib ./lib
COPY --chown=node:node --from=build /app/worker ./worker
COPY --chown=node:node --from=build /app/prisma ./prisma
COPY --chown=node:node --from=build /app/scripts ./scripts
COPY --chown=node:node --from=build /app/prisma.config.ts ./prisma.config.ts
COPY --chown=node:node --from=build /app/next.config.ts ./next.config.ts
COPY --chown=node:node --from=build /app/tsconfig.json ./tsconfig.json
COPY --chown=node:node --from=build /app/package.json ./package.json

EXPOSE 3000
USER node
# Default to the web process — the worker service overrides this with
# `command: ["npm", "run", "worker"]` in whatever compose/stack file deploys
# it (see openreply-vps.stack.yml in EvolutionAPI/omni-nexus for an example).
CMD ["npm", "run", "start"]
