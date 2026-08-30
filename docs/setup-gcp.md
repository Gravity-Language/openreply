# Self-hosting OpenReply on a GCP VM

This guide deploys all of OpenReply to one Compute Engine VM:

- Caddy for HTTPS and reverse proxying
- the Next.js web/API process
- the always-on BullMQ worker
- the scheduler in `scripts/cron.sh`
- PostgreSQL 16
- Redis 7

Artifact Registry stores immutable application images, Secret Manager stores the
production environment, and Cloud Storage receives daily PostgreSQL backups.
PostgreSQL and Redis never publish host ports; only Caddy exposes ports 80 and
443.

This topology is intended for a small, single-zone installation. It trades high
availability for a simple and predictable deployment. Daily off-VM backups and
reboot recovery are part of the minimum setup, not optional follow-up work.

## Defaults used by the scripts

| Setting | Default |
| --- | --- |
| Project ID | `learngravity-openreply` |
| Region | `us-west1` |
| Zone | `us-west1-b` |
| VM | `openreply-prod`, `e2-medium`, Ubuntu 24.04 LTS |
| Public domain | `reply.learngravity.com` |
| Artifact Registry repository | `openreply` |
| Secret Manager secret | `openreply-production-env` |
| Backup bucket | `<project-id>-openreply-backups` |

Override a default with the corresponding `OPENREPLY_*` environment variable
shown near the top of each script.

## Before you begin

You need:

- an authenticated Google Cloud CLI with permission to create a project and
  attach billing;
- a Cloudflare account that controls `learngravity.com`;
- a Git checkout with a clean, reviewed commit;
- later, a Resend API key and verified sender;
- later, an Instagram Business or Creator account and a Meta Business app.

Authenticate Google Cloud locally:

```bash
gcloud auth login
gcloud auth application-default login
```

## 1. Validate the application

Use Node 22, as pinned by `.nvmrc` and `package.json`:

```bash
nvm use
npm ci
npm run db:generate
npm run typecheck
npm run lint
npm test
npm run build
npm audit --omit=dev
docker build -t openreply:local .
OPENREPLY_ENV_FILE=.env.gcp.example \
  docker compose --env-file .env.gcp.example -f compose.gcp.yml config
```

Do not proceed with an unresolved critical dependency advisory.

## 2. Provision the GCP foundation

The provisioning script is idempotent. It creates or reuses the dedicated
project, links billing, enables APIs, creates a least-privilege VM service
account, registry, bucket, static IP, firewall rules, and VM:

```bash
./scripts/gcp/provision.sh
```

If more than one billing account is available, pass the intended account:

```bash
OPENREPLY_GCP_BILLING_ACCOUNT=000000-000000-000000 \
  ./scripts/gcp/provision.sh
```

The script prints the reserved IPv4 address at the end.

## 3. Create the DNS record

In Cloudflare, open `learngravity.com`, then **DNS → Records → Add record**:

- Type: `A`
- Name: `reply`
- IPv4 address: the reserved address printed by `provision.sh`
- Proxy status: **DNS only** while Caddy obtains its first certificate
- TTL: Auto

Do not point Meta at a temporary hostname. The permanent URLs are:

```text
https://reply.learngravity.com/api/instagram/callback
https://reply.learngravity.com/api/webhook
```

## 4. Build and publish the application image

The build script refuses a dirty tree so the image tag always identifies the
exact source commit:

```bash
./scripts/gcp/build-image.sh
```

Cloud Build creates a `linux/amd64` image and pushes it to Artifact Registry as
`sha-<git-sha>`.

## 5. Store the production environment

Run the interactive secret configurator:

```bash
./scripts/gcp/configure-secrets.sh
```

The script:

- generates `NEXTAUTH_SECRET`, `CRON_SECRET`, `ENCRYPTION_KEY`,
  `WEBHOOK_VERIFY_TOKEN`, and data-service passwords on the first run;
- asks for the allowed login email, sender identity, Resend key, Meta values,
  and image tag;
- uploads the complete environment directly to Secret Manager;
- grants the VM service account access to that one secret;
- deletes the temporary local file without printing secret values.

It is safe to enter `pending` for Resend and Meta during the infrastructure
phase. Login email and Instagram connection will not work until those values
are replaced with real credentials in a new secret version.

On later runs, pressing Enter keeps existing credentials and generated values.
The script never rotates database, Redis, auth, encryption, cron, or webhook
secrets implicitly. Export an individual variable before running it when you
intend to replace that value.

`ENCRYPTION_KEY` is durable data. Losing or changing it means every connected
Instagram account must reconnect.

## 6. Release to the VM

The release script uploads only the deployment bundle through IAP, bootstraps
Docker and the Google Cloud CLI, installs the backup timer, pulls the immutable
image, starts PostgreSQL and Redis, runs migrations once, and starts the web,
worker, Caddy, and cron services:

```bash
./scripts/gcp/release.sh
```

The deployment is successful only after the internal health endpoint reports:

```json
{
  "status": "ok",
  "checks": {
    "worker": {
      "healthy": true
    }
  }
}
```

Then confirm the public endpoint:

```bash
curl --fail --show-error https://reply.learngravity.com/api/health
```

After Caddy has a valid certificate, Cloudflare proxying may be enabled if
desired. Use Full (strict) TLS so Cloudflare continues validating the origin.

## 7. Verify recovery before Meta setup

Reboot the VM and verify the Compose restart policies recover the stack:

```bash
gcloud compute instances reset openreply-prod \
  --project=learngravity-openreply \
  --zone=us-west1-b
```

After recovery, check health again. Then trigger and inspect a backup:

```bash
gcloud compute ssh openreply-prod \
  --project=learngravity-openreply \
  --zone=us-west1-b \
  --tunnel-through-iap \
  --command='sudo /opt/openreply/scripts/gcp/backup.sh'

gcloud storage ls gs://learngravity-openreply-openreply-backups/
```

The systemd timer runs daily at approximately 04:15 UTC and the bucket lifecycle
deletes backups older than 35 days. Cloud Storage soft delete provides an
additional recovery window.

`restore.sh` is intentionally guarded. It refuses to run without both a backup
URL and the literal `--confirm-destructive-restore` argument. Do not perform a
restore against production unless current data loss is understood and approved.

## 8. Configure Resend

Verify `learngravity.com` in Resend using the DNS records Resend provides. Set a
sender such as:

```text
OpenReply <login@learngravity.com>
```

Run `configure-secrets.sh` again with the real Resend key, then run
`release.sh`. Confirm a magic link reaches the address in `ALLOWED_EMAILS`.

## 9. Configure Meta

Follow the Meta section in [setup.md](setup.md#the-meta-app) one step at a time,
using the GCP domain instead of a Vercel domain.

For accounts you control:

1. Create a Business-type Meta app with **Manage messaging and content on
   Instagram** and Instagram Login.
2. Collect `INSTAGRAM_APP_ID`, `INSTAGRAM_APP_SECRET`, and
   `FACEBOOK_APP_SECRET`.
3. Add every controlled Instagram account as a tester and accept each invite
   inside Instagram.
4. Register the exact OAuth redirect and webhook URLs above.
5. Subscribe to both `comments` and `messages`.
6. Publish the app so real webhooks are delivered.
7. Run `configure-secrets.sh` with the real Meta values and release again.

If the Meta screen differs from the primary setup guide, stop and capture a
screenshot. Do not guess at new labels or navigation.

## 10. End-to-end test

1. Connect the controlled Instagram account in OpenReply.
2. Create a campaign with a unique keyword.
3. Comment that keyword from a second account.
4. Confirm the DM arrives.
5. Confirm a `SENT` row appears in the DM Logs page and `DmLog` table.

Diagnose in this order:

- `WebhookEvent`: did Meta deliver the event?
- `DmLog`: did matching or sending fail?
- `OperationalEvent`: did the worker or reconciler fail?

The installation is complete when `/api/health` is healthy after a reboot, a
backup exists off the VM, and a real comment produces a `SENT` DM log row.

## GCP setup-agent prompt

Paste this prompt into a trusted coding agent inside this repository:

```text
You are helping me deploy OpenReply to a dedicated GCP Compute Engine VM for
Instagram accounts I control. Read README.md, docs/setup.md, and
docs/setup-gcp.md completely before taking action.

Use the existing GCP scripts and work in order:

1. Validate the repo on Node 22: generate Prisma, typecheck, lint, test, build,
   audit production dependencies, build the Docker image, and render the GCP
   Compose configuration. Stop on any critical advisory or failed check.
2. Run scripts/gcp/provision.sh. Stop for billing, IAM, or organization-policy
   actions only I can complete.
3. Give me the reserved IP and wait for me to add the reply.learngravity.com A
   record in Cloudflare with proxying disabled initially.
4. Build and publish the immutable image with scripts/gcp/build-image.sh.
5. Run scripts/gcp/configure-secrets.sh. Generate secrets without printing them
   or asking me to paste them into chat. Ask me for Resend and Meta values only
   through the secure interactive prompt. Preserve ENCRYPTION_KEY.
6. Release with scripts/gcp/release.sh. Confirm /api/health returns status ok
   and worker.healthy true. Verify reboot recovery and an off-VM backup before
   starting Meta setup.
7. Walk through the Meta section of docs/setup.md one screen at a time using
   reply.learngravity.com. Never invent Meta dashboard steps; ask me for a
   screenshot whenever the screen differs.
8. Create a test campaign and have me comment from a second account. Diagnose
   through WebhookEvent, DmLog, and OperationalEvent, in that order.

Do not expose PostgreSQL or Redis ports. Do not deploy an uncommitted image. Do
not perform a restore, secret rotation, deletion, or rollback without explicit
approval. Remind me to rotate any secret that crosses an unsafe channel.

You are finished only when health survives a reboot, a Cloud Storage backup is
verified, and a real comment creates a SENT DmLog row.
```
