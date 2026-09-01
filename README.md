# nwws-nginx — hermes cache node in front of the NWWS-OI origin

nginx (1.20.1, Oracle Linux 9) running on **oracle-hermes** (`129.80.186.193`)
as a radar-tile + basemap-vtile cache in front of the NWWS-OI origin
(`150.136.125.244:8443`).

```
Phone ──▶ hermes nginx :8443 (this cache) ──▶ origin 150.136.125.244:8443
              │                                     │
              └─ proxy_cache radar (8 GB)           └─ aiohttp + S3 (NODD/MRMS)
```

## Layout

| File | Purpose |
|---|---|
| `nginx.conf` | stock Oracle Linux 9 nginx main config (reference) |
| `conf.d/radar-cache.conf` | **the cache node** — listen 8443 ssl http2, proxy_cache, stale-while-revalidate |
| `conf.d/default.conf` | pre-existing :80 site on hermes (nexusforge) — left untouched |
| `ssl/hermes-cert.pem` | public cert only (dual-SAN: hermes + origin IPs). **The private key is NOT in this repo** — see below |
| `scripts/deploy.sh` | copy config to hermes, `nginx -t`, reload |

## Cache policy (radar-cache.conf)

- **Cache key excludes `fcm_token` / `device_secret`** — keyed on
  `$uri` + `site/product/time/min_dbz/despeckle/clutter` only, so every
  device shares the same tile entries (otherwise each device gets its own
  cache entry and there is zero sharing).
- Honors the origin's freshness: `proxy_cache_valid 200 240s` (matches the
  server's `Cache-Control: max-age=240`).
- `proxy_cache_use_stale updating error timeout ...` — stale-while-revalidate:
  a revalidating tile still serves the old copy instead of stalling.
- `proxy_cache_lock on` — a burst of concurrent misses for the same tile
  triggers ONE upstream fetch.
- Only GET tile/times paths are cached; POST/auth endpoints pass through.
- `Host: $http_host` is passed upstream **with the port** — the origin's
  vstyle handler rewrites its vtiles URLs from `request.host`, so the style
  tells MapLibre to fetch vtiles through hermes (`https://129.80.186.193:8443
  /api/v1/vtiles/...`) with the correct port. (Passing a port-less Host made
  the rewrite emit `https://150.136.125.244/...` on port 443 = the website,
  breaking the map.)

## TLS / cert pinning

- The app (`Tempest`) pins the origin's certificate SPKI
  (`sha256/GZsR4aNhRHKwzITrbHxlwlkuUtjEb9kPfN3+fcDdX0A=`).
- Hermes terminates TLS with a **dual-SAN self-signed cert** issued from the
  **origin's keypair**: SAN `IP:129.80.186.193` + `IP:150.136.125.244`.
  Because the SPKI is the origin key's public key, the app's pin validates
  unchanged against hermes.
- **The private key lives only on the boxes** (`/etc/nginx/ssl/hermes-key.pem`
  on hermes, `/opt/nwws-oi/key.pem` on the origin) and in the encrypted backup
  (`/opt/nwws-oi/data/backups`). It is deliberately **not** in this repo.
- App side: `network_security_config.xml` trusts the bundled cert for both IP
  domains (MapLibre's style/vtiles HTTP stack uses the system trust store,
  not the pinned OkHttp client). Regenerate the bundled `nwws_cert.pem` from
  `ssl/hermes-cert.pem` when the cert is reissued.

## Gotchas (all hit in production on 2026-09-01)

1. **nginx 1.20** — use `listen 8443 ssl http2;` (a standalone `http2 on;`
   directive is invalid on this version).
2. **SELinux** — nginx's outbound connect to the origin 8443 was denied
   (`connect() ... (13: Permission denied)`) until
   `sudo setsebool -P httpd_can_network_connect 1`.
3. **Two firewalls** — OCI VCN security list AND the box's own `firewalld`
   both had to open 8443/tcp:
   - OCI: ingress rule Source `0.0.0.0/0`, TCP, dest port 8443 on the hermes
     subnet's security list.
   - Box: `sudo firewall-cmd --permanent --add-port=8443/tcp && sudo firewall-cmd --reload`.
4. **Stale MapLibre cache** — after changing the vtiles host, the phone kept
   serving the old style JSON from `/data/data/dev.radar.isobaric/files/mbgl-offline.db`
   (a cache-dir clear alone does not remove it). Delete that file and
   force-stop the app to pick up a re-rewritten style.

## Deploy

```bash
bash scripts/deploy.sh            # needs SSH access to oracle-hermes
```

The script copies `conf.d/*` and `ssl/hermes-cert.pem` to hermes, runs
`nginx -t`, and reloads if valid. It does NOT touch the private key (it must
already be present at `/etc/nginx/ssl/hermes-key.pem` on the box).
