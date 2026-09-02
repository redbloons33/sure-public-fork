# Self-hosting Sure with Docker

This repo runs as four containers defined in [`compose.yml`](../../compose.yml): `web`, `worker`,
`db` (PostgreSQL 16), and `redis`. The `web` and `worker` images are **built locally** from the
`Dockerfile` in this repo (`image: sure-local:latest`) — there is no external image to pull.

## Setup

### 1. Install Docker

Install Docker Engine ([official guide](https://docs.docker.com/engine/install/)) and confirm it runs:

```bash
docker run hello-world
```

### 2. Create your environment file

```bash
cp .env.example .env
```

Generate a secret and put it in `.env` as `SECRET_KEY_BASE`:

```bash
openssl rand -hex 64
# no openssl?  head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n' && echo
```

The values that matter for a basic Docker run:

```txt
SECRET_KEY_BASE=<the generated string>
POSTGRES_PASSWORD=<a database password you choose>
```

`compose.yml` supplies sensible defaults for everything else (`POSTGRES_USER=sure_user`,
`POSTGRES_DB=sure_production`, `DB_HOST=db`, `REDIS_URL=redis://redis:6379/1`, `SELF_HOSTED=true`).
Any variable you set in `.env` overrides the default. See `.env.example` for the full list
(SMTP, S3/R2 storage, OIDC, Plaid, OpenAI, etc.) — all optional.

### 3. Build and start

```bash
docker compose up -d --build
```

Open `http://localhost:3000` and register an account with "create your account".

### Running behind HTTPS

If a reverse proxy terminates TLS in front of the container, set `RAILS_ASSUME_SSL: "true"` in the
`web` service environment in `compose.yml` (default is `"false"` for plain-HTTP local use).

### Binding to IPv6 (optional)

By default the container listens on `0.0.0.0:3000` and Docker publishes it on the host's IPv4
interface. To also serve IPv6, set `BINDING: "::"` in the `web` environment and add a bracketed-host
port entry alongside the existing one:

```yaml
services:
  web:
    ports:
      - ${PORT:-3000}:3000
      - "[::]:${PORT:-3000}:3000"
    environment:
      <<: *rails_env
      BINDING: "::"
```

On Linux/macOS the `[::]` bind is dual-stack, so it accepts both IPv4 and IPv6 clients.

## Updating

```bash
git pull
docker compose up -d --build
```

The `web` container's entrypoint (`bin/docker-entrypoint`) runs `db:prepare` on boot, so pending
migrations are applied automatically.

## Backups

`compose.yml` includes an optional `backup` service that runs daily `pg_dump` snapshots to
`/opt/sure-data/backups` on the host (edit that path in `compose.yml`). Enable it with:

```bash
docker compose --profile backup up -d
```

To move an existing instance to a new host, see
[migrating-to-a-new-host.md](migrating-to-a-new-host.md).

## Troubleshooting

### ActiveRecord::DatabaseConnectionError on first run

Usually means Docker already initialised the Postgres volume with different credentials from an
earlier attempt. Reset the database volume (**this deletes all data in the Sure database**):

```bash
docker compose down
docker volume rm sure_postgres-data
docker compose up -d --build
```

### Slow CSV imports

CSV import work runs in the `worker` container and needs Redis. Check `docker compose logs worker`
for Redis connection errors.

### IPv6 / "Failed to open TCP connection" during sync

If outbound syncs (e.g. Yahoo Finance) fail because DNS resolves to IPv6 first inside a container
without IPv6, `compose.yml` already sets explicit IPv4 DNS servers (`8.8.8.8`, `1.1.1.1`). You can
also pin hosts via `extra_hosts:` in the `web`/`worker` services.
