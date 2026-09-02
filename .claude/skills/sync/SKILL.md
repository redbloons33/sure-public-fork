---
name: sync
description: Manually trigger a full sync of all Plaid and SnapTrade accounts in the Docker environment
user-invocable: true
---

# Sync All Accounts

Queues sync jobs for every Plaid item and SnapTrade item in the running Docker instance.

## Steps

1. Queue sync jobs for all providers:

```bash
docker exec sure-web-1 bin/rails runner "
PlaidItem.all.each { |pi| SyncJob.perform_later(pi.syncs.create!) }
SnaptradeItem.all.each { |si| SyncJob.perform_later(si.syncs.create!) }
puts 'Queued sync jobs'
"
```

2. Watch worker logs to confirm completion:

```bash
docker logs sure-worker-1 --since=120s 2>&1 | grep -E "SyncJob elapsed|complete|fail|ERROR" | tail -30
```

## Notes

- The app runs in Docker (`sure-web-1` / `sure-worker-1`). Code is baked into the image — if you've made local code changes, run `docker compose down && docker compose up --build -d` before syncing.
- Plaid items and SnapTrade items each have their own `Sync` record created via `syncs.create!` — `SyncJob` expects a `Sync` instance, not the item directly.
- Syncs run in parallel via Sidekiq. Watch for `class=SyncJob elapsed=...: done` lines to confirm each finishes.
