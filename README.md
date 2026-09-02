# Sure

A self-hosted personal finance app, run with Docker.

This repository is a trimmed-down fork of the community [Sure](https://github.com/we-promise/sure)
project, which is itself a fork of the archived [Maybe Finance](https://github.com/maybe-finance/maybe)
app. It keeps only what is needed to build and run the web app with Docker Compose.

## Running with Docker

See [docs/hosting/docker.md](docs/hosting/docker.md) for the full guide. Short version:

```sh
cp .env.example .env
# edit .env: set SECRET_KEY_BASE (openssl rand -hex 64) and POSTGRES_PASSWORD
docker compose up -d --build
```

Then open http://localhost:3000 and create an account.

The stack is four containers, all defined in [`compose.yml`](compose.yml):

| Service  | Purpose                                    |
|----------|--------------------------------------------|
| `web`    | Rails web server (built from `Dockerfile`) |
| `worker` | Sidekiq background jobs                     |
| `db`     | PostgreSQL 16                              |
| `redis`  | Redis (Sidekiq queue + cache)             |

An optional `backup` service (`--profile backup`) runs daily `pg_dump` snapshots.

## Local development

Requires Ruby (see `.ruby-version`), PostgreSQL, and Redis running locally.

```sh
cp .env.example .env
bin/setup
bin/dev            # Rails + Sidekiq + Tailwind watcher
```

Optionally load demo data with `rake demo_data:default` (login `user@example.com` / `Password1!`).

## License

Distributed under an [AGPLv3 license](https://github.com/we-promise/sure/blob/main/LICENSE).

- "Maybe" is a trademark of Maybe Finance, Inc. This fork is **not affiliated with or endorsed by**
  Maybe Finance Inc.
- "Sure" refers to the community fork this repo is based on.
