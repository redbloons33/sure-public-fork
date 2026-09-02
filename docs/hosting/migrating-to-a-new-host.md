 Secrets: Copy .env over. Critical: the existing SECRET_KEY_BASE must move with you. Your 4 Plaid access_tokens are encrypted with a key
   derived from it — regenerate it and the tokens become unreadable (you'd have to re-link = pay Plaid fees again). Scp it or copy-paste;
   don't generate a new one.

  Database: dump → scp → restore.
  # on old machine (Windows, from the repo dir):
  docker compose exec -T db pg_dump -U sure_user -Fc sure_production > sure.dump

  # scp to VM:
  scp sure.dump .env compose.yml user@vm:/home/user/sure/

  # on VM:
  cd ~/sure
  docker compose up -d db             # start only the DB first
  # wait ~5s for postgres to accept connections, then:
  docker compose exec -T db pg_restore -U sure_user -d sure_production --clean --if-exists < sure.dump
  docker compose up -d                # bring up web + worker + redis

  The -Fc / pg_restore pair (custom format) handles schema + data + sequences correctly. Skip --clean --if-exists if you want it to      
  complain instead of overwriting.

  App-storage volume: empty in your case, skip. If it mattered:
  # old:
  docker run --rm -v sure_app-storage:/src alpine tar czf - -C /src . > app-storage.tgz
  # new (after compose up creates the empty volume):
  cat app-storage.tgz | docker run --rm -i -v sure_app-storage:/dst alpine tar xzf - -C /dst

  Redis: skip entirely. It's just the Sidekiq job queue; next sync tick rebuilds state.