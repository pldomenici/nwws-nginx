# nwws-nginx — nginx config for oracle-hermes (cache node + API edge)

nginx 1.20.1 on Oracle Linux 9, running on **oracle-hermes**
(`129.159.173.84`, `api.isobaricradar.com`). The NWWS-OI origin is
**co-located on the same box** (podman container, TLS on `127.0.0.1:8444`),
so this nginx serves as the TLS edge + radar-tile / basemap-vtile cache in
front of it.

```
Phone ──▶ nginx :8443 (this cache/TLS edge) ──▶ origin 127.0.0.1:8444 (aiohttp, podman)
              │
              └─ proxy_cache radar (16 GB) + map (8 GB), on /var/cache/nginx
```

## Layout

| File | Purpose |
|---|---|
| `nginx.conf` | main config (minimal). The stock `server { listen 80; server_name _; }` block was removed 2026-09-06 — it never matched a request and only caused "conflicting server name" warnings; `isobaric.conf` owns `:80 default_server` |
| `conf.d/radar-cache.conf` | **the cache node** — listen 8443 ssl http2, proxy_cache, stale-while-revalidate; everything else passes through |
| `conf.d/isobaric.conf`, `conf.d/isobaric-ssl.conf` | **NOT in this repo** — isobaricradar.com website blocks on 80/443 (Let's Encrypt), installed by the website deploy. nginx.conf must not redeclare their listeners |
| `ssl/hermes-cert.pem` | public cert only (CN + SAN `api.isobaricradar.com`, SAN IPs of hermes + legacy hosts). **The private key is NOT in this repo** — see TLS below |
| `scripts/deploy.sh` | copy nginx.conf + radar-cache.conf + cert to the box, `nginx -t`, reload |

## Cache policy (radar-cache.conf)

Two zones with deliberately different eviction policies, both on the root
filesystem (183G) under `/var/cache/nginx` (SELinux `httpd_cache_t`):

- **radar** (`keys_zone=radar:128m`, `max_size=16g`, `inactive=24h`): radar
  tile images (`radar_dbz`, `radar_tiles` PNG, `radar_dbz_times`/`meta`/`time`).
  Evicted after 24 h without requests; freshness is origin-driven
  (Cache-Control is honored — `proxy_ignore_headers` removed): per-site tiles
  `max-age=86400`, MRMS_* mosaics `240s`, stale-while-error fallbacks
  `no-store` (never cached). `proxy_cache_valid 200 24h` is only a fallback
  for responses without explicit Cache-Control.
- **map** (`keys_zone=map:64m`, `max_size=8g`, `inactive=14d`): basemap
  vector tiles (`vtiles/*.pbf`) — immutable per z/x/y, `proxy_cache_valid 200 7d`.

Key rules (all learned in production):

- **Cache keys exclude `fcm_token` / `device_secret`** — keyed on
  `$uri` + `site/product/time/min_dbz/despeckle/clutter` (+ `after/limit` for
  `radar_dbz_times`) only, so every device shares tile entries. The times
  endpoint MUST be keyed on `after=`/`limit=`, or an incremental slide-in
  request hits the cached initial answer and stalls (fixed 2026-09-05).
- **vstyles are NOT cached** — their JSON is rewritten per-device with that
  device's auth baked into tile URLs; caching would leak tokens.
- `proxy_cache_use_stale updating error timeout http_500 http_502 http_503` —
  stale-while-revalidate: a revalidating/erroring tile still serves the old
  copy instead of stalling.
- `proxy_cache_lock on` — a burst of concurrent misses for the same tile
  triggers ONE upstream fetch.
- Only GET tile/times paths are cached; POST/auth/register pass through.
- `Host: $http_host` is passed upstream **with the port** — the origin's
  vstyle handler rewrites its vtiles URLs from `request.host`, so the style
  tells MapLibre to fetch vtiles back through this cache
  (`https://api.isobaricradar.com:8443/api/v1/vtiles/...`).

## TLS / cert pinning

- The app pins the **origin keypair's** SPKI
  (`sha256/GZsR4aNhRHKwzITrbHxlwlkuUtjEb9kPfN3+fcDdX0A=`).
- This box terminates TLS on :8443 with a **multi-SAN self-signed cert issued
  from the same keypair** as the origin (`/opt/nwws-oi/{cert,key}.pem`):
  SAN `DNS:api.isobaricradar.com` + the hermes/origin public IPs. Because the
  SPKI is the origin key's public key, the app's pin validates unchanged.
- Verified 2026-09-06: nginx key == origin key, key matches cert, live SPKI
  on both :8443 and :8444 equals the pin. TLS 1.0/1.1 refused; 1.2 + 1.3
  offered. Cert valid 2026-09-02 → 2036-08-30.
- **The private key lives only on the boxes** (`/etc/nginx/ssl/hermes-key.pem`
  here, `/opt/nwws-oi/key.pem` on the origin) and in the encrypted backup
  (`/opt/nwws-oi/data/backups`). Deliberately not in this repo.
- Reissuing the cert from the **same key** keeps the pin valid; only a
  keypair change requires regenerating the app's bundled `nwws_cert.pem`
  (from `ssl/hermes-cert.pem`) and republishing.
- App side: `network_security_config.xml` trusts the bundled cert for the
  host domain (MapLibre's style/vtiles HTTP stack uses the system trust
  store, not the pinned OkHttp client).

## Gotchas (all hit in production)

1. **nginx 1.20** — use `listen 8443 ssl http2;` (a standalone `http2 on;`
   directive is invalid on this version).
2. **SELinux** — nginx's outbound connect to the origin was denied
   (`connect() ... (13: Permission denied)`) until
   `sudo setsebool -P httpd_can_network_connect 1`. Cache dirs need
   `semanage fcontext -a -t httpd_cache_t '/var/cache/nginx(/.*)?'` +
   `restorecon -Rv /var/cache/nginx`.
3. **Two firewalls** — OCI VCN security list AND the box's own `firewalld`
   both must allow 8443/tcp from `0.0.0.0/0`.
4. **Stale MapLibre cache** — after changing the vtiles host, the phone kept
   serving old style JSON from
   `/data/data/dev.radar.isobaric/files/mbgl-offline.db` (a cache-dir clear
   alone does not remove it). Delete that file and force-stop the app.
5. **Don't redeclare :80/:443 in nginx.conf** — the website blocks in
   `conf.d/isobaric*.conf` own those listeners; a second `server_name _`
   block only produces warnings (and was the reason the stock block was
   deleted).

## Deploy

```bash
bash scripts/deploy.sh            # needs SSH access to oracle-hermes
```

Copies `nginx.conf`, `conf.d/radar-cache.conf` and `ssl/hermes-cert.pem` to
the box, runs `nginx -t`, and reloads if valid. Does NOT touch the private
key (must already exist at `/etc/nginx/ssl/hermes-key.pem`) and does NOT
touch `conf.d/isobaric*.conf` (website deploy owns those).
