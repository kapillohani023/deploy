# Exact steps: first deploy of this repo to a new EC2

Domains: `www.kapillohani.site` (portfolio, canonical), `kapillohani.site`
(301 to www), `streaks.kapillohani.site`, `t2a.kapillohani.site`.

A push to `main` of **this** repo applies compose/Caddy/env to the server.
A push to `main` of an **app** repo builds that image and restarts only
that service. Do the secret and env steps before the first app-repo push.

---

## 1. Launch the EC2 instance

AWS console, region close to you (e.g. Mumbai `ap-south-1`):

- Ubuntu Server 24.04 LTS, **t3.small** or larger, 20 GB gp3
- Key pair you have the `.pem` for
- Security group:
  - 80 and 443 from anywhere
  - **22 from `0.0.0.0/0`**, key-only SSH (Ubuntu’s default). GitHub Actions
    must be able to reach port 22; locking it to your laptop IP will make
    every deploy fail. Do not open 5432.
- Allocate an **Elastic IP** in the same region and associate it. Call it `EIP`.

```bash
ssh -i /path/to/your.pem ubuntu@EIP
```

If that works, log out and continue.

---

## 2. Point GoDaddy DNS at the new IP

GoDaddy → kapillohani.site → DNS:

1. Delete A records for `@` and `www` that still point at `3.27.174.80`.
2. Add A records, TTL 600, all to `EIP`, for `@`, `www`, `streaks`, and `t2a`.

Leave the Google Search Console TXT record. No CNAME on `@`.

Wait until public DNS is correct before you care about HTTPS:

```bash
dig +short @1.1.1.1 kapillohani.site A
dig +short @1.1.1.1 www.kapillohani.site A
dig +short @1.1.1.1 streaks.kapillohani.site A
dig +short @1.1.1.1 t2a.kapillohani.site A
```

All four must print `EIP`. If you apply Caddy before that, Let’s Encrypt
will fail until you re-run Apply (or wait for Caddy to retry).

---

## 3. Create the private GitHub repo and push this tree

On GitHub: create empty **private** repo `kapillohani023/deploy` (no README).

On the machine that has this tree (already a git repo on `main`):

```bash
cd /path/to/deploy-repo
git remote add origin git@github.com:kapillohani023/deploy.git
git push -u origin main
```

---

## 4. Deploy SSH key and Actions secrets

On your laptop (not the instance, not your personal `.pem`):

```bash
ssh-keygen -t ed25519 -f ~/github-actions-ec2 -C 'github-actions-ec2' -N ''
ssh-copy-id -i ~/github-actions-ec2.pub ubuntu@EIP
ssh -i ~/github-actions-ec2 ubuntu@EIP 'echo ok'
```

In **this** repo (`kapillohani023/deploy`) → Settings → Secrets and variables
→ Actions, add:

| Secret | Value |
|---|---|
| `EC2_HOST` | the Elastic IP |
| `EC2_USER` | `ubuntu` |
| `EC2_SSH_KEY` | full contents of `~/github-actions-ec2` (private key) |

Add the same three secrets to `streaks`, `task-to-api`, and `portfolio`.
In **streaks only**, also add `NEXT_PUBLIC_VAPID_PUBLIC_KEY` (you will
generate the key in step 6).

Open https://github.com/kapillohani023/deploy/settings/actions → **Access**
→ **Accessible from repositories owned by the user**. (Skip this if you
plan to use `templates/deploy.yml` in the app repos instead.)

---

## 5. First Apply (bootstraps Docker on the instance)

In the deploy repo: Actions → **Apply** → **Run workflow**.

That rsyncs the tree to `/opt/deploy`, installs Docker if needed, generates
`POSTGRES_PASSWORD` into `/opt/apps/env/.env`, creates per-app env files and
databases, and starts postgres + caddy. App containers are skipped until
their images exist (step 7).

If you would rather bootstrap over SSH yourself (optional):

```bash
scp -r . ubuntu@EIP:/tmp/deploy-src
ssh ubuntu@EIP 'sudo bash /tmp/deploy-src/scripts/bootstrap.sh'
```

Subsequent pushes to `main` of this repo re-run Apply automatically.

---

## 6. Fill app env files on the instance

```bash
ssh -i ~/github-actions-ec2 ubuntu@EIP
openssl rand -base64 32    # AUTH_SECRET — generate twice, one per app
openssl rand -hex 32       # CRON_SECRET
openssl rand -hex 32       # MCP_SERVER_SECRET
npx --yes web-push generate-vapid-keys
nano /opt/apps/env/streaks.env
nano /opt/apps/env/task-to-api.env
# /opt/apps/env/portfolio.env needs nothing
# /opt/apps/env/.env already has POSTGRES_PASSWORD — leave it
```

**streaks.env:** `AUTH_SECRET`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`,
`VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `NEXT_PUBLIC_VAPID_PUBLIC_KEY`
(same public key in both public fields; also a GitHub secret),
`CRON_SECRET`, `MCP_SERVER_SECRET`. Leave `DATABASE_URL`, `AUTH_URL`,
`NEXTAUTH_URL`. `T2A_API_URL` / `T2A_API_BEARER_TOKEN` can wait until you
create an agent (`https://t2a.kapillohani.site/api/agents/<id>`).
`VAPID_SUBJECT` is already set.

**task-to-api.env:** a *different* `AUTH_SECRET`, plus the Google client
(can be the same client if both redirect URIs are registered). Leave
`DATABASE_URL` and the URLs. Hostname in `DATABASE_URL` must stay `postgres`.

Put the VAPID public key into the streaks repo secret if you have not yet.

---

## 7. Copy deploy files into each app repo and push `main`

From a clone of each app, with this repo checked out at `$DEPLOY`. Do not
push until steps 4 and 6 are done.

```bash
# streaks (Next.js + bun + Prisma)
cd /path/to/streaks
cp "$DEPLOY/templates/Dockerfile.next-bun-prisma" Dockerfile
cp "$DEPLOY/templates/docker-entrypoint.sh" .
cp "$DEPLOY/templates/dockerignore" .dockerignore
chmod +x docker-entrypoint.sh
mkdir -p .github/workflows
cp "$DEPLOY/examples/streaks.deploy.yml" .github/workflows/deploy.yml
git add Dockerfile docker-entrypoint.sh .dockerignore .github/workflows/deploy.yml
git commit -m "Add EC2 deploy workflow"
git push origin main

# task-to-api (same stack)
cd /path/to/task-to-api
cp "$DEPLOY/templates/Dockerfile.next-bun-prisma" Dockerfile
cp "$DEPLOY/templates/docker-entrypoint.sh" .
cp "$DEPLOY/templates/dockerignore" .dockerignore
chmod +x docker-entrypoint.sh
mkdir -p .github/workflows
cp "$DEPLOY/examples/task-to-api.deploy.yml" .github/workflows/deploy.yml
git add Dockerfile docker-entrypoint.sh .dockerignore .github/workflows/deploy.yml
git commit -m "Add EC2 deploy workflow"
git push origin main

# portfolio (Next.js + npm, no Prisma)
cd /path/to/portfolio
cp "$DEPLOY/templates/Dockerfile.next-npm" Dockerfile
cp "$DEPLOY/templates/dockerignore" .dockerignore
mkdir -p .github/workflows
cp "$DEPLOY/examples/portfolio.deploy.yml" .github/workflows/deploy.yml
git add Dockerfile .dockerignore .github/workflows/deploy.yml
git commit -m "Add EC2 deploy workflow"
git push origin main
```

Watch Actions in each app repo. All three must go green.

---

## 8. Google OAuth

[Credentials](https://console.cloud.google.com/apis/credentials) → your
Web client.

Origins: `https://streaks.kapillohani.site`, `https://t2a.kapillohani.site`.

Redirects:

- `https://streaks.kapillohani.site/api/auth/callback/google`
- `https://t2a.kapillohani.site/api/auth/callback/google`

If you edit the env files after the first deploy:

```bash
bash /opt/deploy/scripts/up-app.sh streaks streaks-cron
bash /opt/deploy/scripts/up-app.sh task-to-api
```

---

## 9. Make GHCR packages public

https://github.com/users/kapillohani023/packages — for `streaks`,
`task-to-api`, and `portfolio`, set visibility to **Public**. Until then,
only the Actions job (which logs in with `GITHUB_TOKEN`) can pull.

---

## 10. Verify

```bash
curl -sI https://www.kapillohani.site | head
curl -sI https://kapillohani.site | head          # 301 to www
curl -sI https://streaks.kapillohani.site | head
curl -sI https://t2a.kapillohani.site | head

ssh ubuntu@EIP 'cd /opt/deploy && bash scripts/apply.sh'
# or: docker compose --project-name deploy ps   (from /opt/deploy, with env file)
```

Expect Caddy + postgres + the three apps + `streaks-cron`. Apex 301s to www.
Apps may 302 to `/signin`, which is still success.

---

## Adding a new project

```bash
./scripts/new-app.sh blog blog --db     # blog.kapillohani.site, with Postgres
git add apps/blog && git commit -m "Add blog" && git push origin main
```

Then follow the printed next steps (DNS A record, Dockerfile, caller
workflow, app-repo secrets, fill `/opt/apps/env/blog.env`, push the app).

---

## Troubleshooting

- **Apply / app deploy: Permission denied (SSH)** — `EC2_SSH_KEY` is the
  private key, `EC2_USER` is `ubuntu`, port 22 is open to GitHub runners
  (see step 1).
- **Reusable workflow not found / not allowed** — step 4 Access setting,
  or switch the app repo to `templates/deploy.yml`.
- **502 from Caddy** — that app image is not on the box yet, or the
  container crashed. `bash /opt/deploy/scripts/apply.sh` and
  `docker compose --project-name deploy logs <service>`.
- **Certificate errors** — DNS is not on `EIP` yet. Wait, then re-run Apply.
- **Prisma migrate failed** — `DATABASE_URL` password must match
  `POSTGRES_PASSWORD` in `/opt/apps/env/.env`; host must be `postgres`.
- **redirect_uri_mismatch** — exact URIs in step 8, then `up-app.sh`.
- **VAPID not baked in** — `NEXT_PUBLIC_VAPID_PUBLIC_KEY` is a *build-time*
  secret in the streaks repo; re-run that workflow after setting it.
