# deploy

Private GitOps repo for `kapillohani023` apps on one EC2 instance. Push to
`main` here and GitHub Actions rsyncs the tree to `/opt/deploy` and applies
it. Each application repo still builds its own image and starts only that
service on push to `main`.

Nothing in this repository has been pushed yet. See [STEPS.md](STEPS.md)
for the copy-paste runbook.

## Layout

```
compose.yml                 postgres + caddy only
Caddyfile                   import snippets + apps/*/site.caddy
apps/<name>/
  compose.yml               service fragment (image, env_file, healthcheck)
  site.caddy                site block(s)
  env.example               copied once to /opt/apps/env/<name>.env
  db                        optional; contents = database name
  extra-services            optional; e.g. streaks-cron
scripts/apply.sh            idempotent apply (run on the server)
scripts/up-app.sh           pull + recreate one service
scripts/bootstrap.sh        one-time Ubuntu 24.04 install
scripts/new-app.sh          scaffold a new app
```

Adding an app never requires editing `compose.yml`. `scripts/lib.sh` passes
`-f apps/*/compose.yml` to Docker Compose, so a new folder is picked up on
the next apply. (This needs Compose v2.20+; `bootstrap.sh` installs Docker’s
current plugin.)

Secrets live in `/opt/apps/env/` on the server and are never committed.

## Hosts

| Hostname | App |
|---|---|
| `www.kapillohani.site` | portfolio (canonical) |
| `kapillohani.site` | 301 → `https://www.kapillohani.site…` |
| `streaks.kapillohani.site` | streaks (Postgres + cron sidecar) |
| `t2a.kapillohani.site` | task-to-api (Postgres) |

## How a change gets to the server

- **This repo, push to `main`:** workflow `Apply` rsyncs to `/opt/deploy` and
  runs `apply.sh`. That creates missing env files and databases, starts
  postgres + caddy, starts any app whose image is already on the box, reloads
  Caddy (zero-downtime config), and prunes dangling images. It does **not**
  pull app images (those come from the app-repo workflow). Missing images are
  skipped so the first apply works before any app has been built.
- **An app repo, push to `main`:** a tiny workflow calls
  `.github/workflows/app-deploy.yml` in this repo (or the self-contained
  fallback in `templates/deploy.yml`). That builds with Buildx + the GitHub
  Actions cache, pushes `ghcr.io/kapillohani023/<name>:<sha>` and `:latest`,
  then SSHs in, `docker login`s with the job token, and runs `up-app.sh` for
  just that service.

The first app deploy works while the GHCR package is still private because
the job logs into GHCR on the server with `GITHUB_TOKEN`. After the first
success, make the package public (or later manual pulls will fail).

## Pushing this repo the first time

From the extracted tree (after you create the empty private repo
`kapillohani023/deploy`):

```bash
cd /path/to/deploy-repo
git remote add origin git@github.com:kapillohani023/deploy.git
git push -u origin main
```

If you are starting from the tarball and this folder is already a git repo
on `main`, you only need the `remote add` and `push`. Then add the three
Actions secrets `EC2_HOST`, `EC2_USER`, `EC2_SSH_KEY` and follow STEPS.md
(install the deploy SSH public key on the instance first).

The first `Apply` run bootstraps Docker on a fresh Ubuntu 24.04 box, so you
do not need to clone this repo on the server yourself.

## Adding a new project

```bash
./scripts/new-app.sh blog blog --db          # -> blog.kapillohani.site
./scripts/new-app.sh www www.example.com     # FQDN; www.* also 301s the apex
```

Then:

1. Commit `apps/<name>/` and push `main` of **this** repo (Caddy + env + DB).
2. Add a DNS A record for the hostname to the Elastic IP. Wait until
   `dig +short @1.1.1.1 <host>` shows that IP, then re-run Apply or wait
   for Caddy to retry certificates.
3. In the app repo: copy `templates/Dockerfile.next-npm` (or
   `Dockerfile.next-bun-prisma` + `docker-entrypoint.sh`),
   `templates/dockerignore` as `.dockerignore`, and
   `examples/app-deploy-caller.yml` as `.github/workflows/deploy.yml`
   (set `service:` / `extra_services:`).
4. Add `EC2_HOST`, `EC2_USER`, `EC2_SSH_KEY` to the app repo secrets.
5. Enable reusable-workflow access once (below).
6. Fill `/opt/apps/env/<name>.env` on the server, then push `main` of the
   app repo.

## Reusable workflow access

Because this repo is private, a calling workflow in another repo is denied
until you open:

`https://github.com/kapillohani023/deploy/settings/actions`

→ **Access** → **Accessible from repositories owned by the user**.

If you would rather not do that, copy `templates/deploy.yml` into the app
repo instead of the caller. It is self-contained and talks to `up-app.sh`
the same way.

`secrets: inherit` passes secrets from the *app* repo, not from this one.
Each app repo needs its own `EC2_HOST`, `EC2_USER`, and `EC2_SSH_KEY`.
Streaks also needs `NEXT_PUBLIC_VAPID_PUBLIC_KEY` (build-time).
