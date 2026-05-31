# MotoRider NAS sync — PocketBase

Backend for syncing the Flutter app's local SQLite to a database on the
Ugreen NAS. Single Docker container running PocketBase, reachable over
Tailscale.

## What's here

| File | Purpose |
| --- | --- |
| `docker-compose.yml` | Pulls a pinned PocketBase image, mounts data + migrations, exposes 8090. |
| `pb_migrations/*.js` | Declarative schema. PocketBase auto-runs anything new in this folder on container start, so the collection is reproducible from a clean volume. |
| `pb_data/` (git-ignored) | Runtime: the SQLite DB and uploaded files. Lives on the NAS, not in git. |

## First-time setup on the NAS

1. **Get the repo on the NAS.** SSH in via Tailscale and clone:

   ```sh
   git clone <repo-url> ~/motorider
   cd ~/motorider/nas
   ```

   (Or just copy the `nas/` folder over via SCP / Ugreen file manager — nothing here depends on the rest of the repo.)

2. **Boot the container.**

   ```sh
   docker compose up -d
   docker compose logs -f pocketbase
   ```

   First boot creates `./pb_data/` and applies the migrations in `pb_migrations/`. You should see a log line `Applied migrations: 1780574400_init_fillups.js`.

3. **Create the superuser** (one time).

   Open the admin UI in a browser via Tailscale: `http://<nas-tailscale-name>:8090/_/`

   You'll be prompted to set the superuser email + password. Use a long random password — this is your break-glass admin.

4. **Create the app user** (regular auth user, used by the phone).

   In the admin UI: `Collections → users → New record`. Set:
   - email: anything, e.g. `motorider@local`
   - password: long random string

   This is the credential the Flutter app will use. Save the password somewhere; you'll paste it into the app's Settings screen when we build it.

5. **Sanity-check the collection.**

   `Collections → fillups` should exist with all fields (`client_id`, `date_iso`, `odometer_km`, `liters`, …, `updated_at`, `deleted_at`).

## Notes

- **Architecture:** the image we use is multi-arch; works on both Intel and ARM Ugreen models.
- **Backups:** `pb_data/` is one SQLite file plus any uploads. Snapshot or rsync that folder and you have a full backup.
- **Schema changes:** add a new file to `pb_migrations/` with a higher timestamp prefix and restart the container. Never edit applied migrations.
- **Updating PocketBase:** bump the version tag in `docker-compose.yml`, then `docker compose pull && docker compose up -d`. Read the release notes for breaking changes first.
- **Access rules:** v1 allows any authenticated user (you only create one). Tighten later by replacing the `@request.auth.id != ""` rules in a follow-up migration to pin a specific user id.

## Tailscale endpoint for the app

The Flutter app needs the NAS reachable as something like:

```
http://<nas-tailscale-name>:8090
```

Confirm it works from your phone (with Tailscale on) by visiting that URL in a browser — you should see the PocketBase landing page.
