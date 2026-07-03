---
title: "Web Manager — Splash, Status, HTTPS & Tokens — display-pi"
description: What the browser-based Kiosk Manager does, plus putting it behind HTTPS with Let's Encrypt and rotating its access token when a link leaks.
---

# The Web Manager

The **Kiosk Manager** is the browser-based tool volunteers use to run the
display — no terminal, no SSH key, works from a phone. It's a small web app the
kiosk serves on the Pi; you reach it at the volunteer link
(`http://displaypi/?token=…`, or `https://kiosk.example.org/?token=…` once TLS
is set up — see below). `make setup-web` installs it; `make provision` includes
that step.

## What the manager does

**Splash images** (left column)
: Upload PNG/JPEG slides (exactly 1920×1080, ≤ 10 MB), delete or download
  existing ones, and drag-and-drop (or use the ↑↓ buttons) to reorder the
  rotation. Changes take effect on the next **Restart Service**.

**Kiosk controls**
: **Restart Service** applies image changes immediately; **Reboot Pi** takes
  about 30 seconds. Both ask for confirmation first.

**Access Link**
: Shows the current volunteer link with a **Copy** button, downloads a
  `.webloc` (Mac) or `.url` (Windows/Linux) double-click shortcut generated from
  the live token, and offers **Rotate Token** — see
  [token rotation](#2-rotating-the-access-token) below.

**System Status** (right column)
: A live health board — the same one shown on the HDMI screen at boot — that
  auto-refreshes every 15 seconds. Each check is green (OK), amber (warning), or
  red (error), with a summary banner rolling up the worst:

  - **Hostname**, **Network** (IP), **Gateway**, **Link** (carrier + speed),
    **Link Errors**
  - **nginx RTMP** (service + port 1935), **RTMP Stream** (is a feed live?)
  - **Kiosk Player** — player/compositor liveness, read from the health monitor
  - **Disk**, **Memory**, **CPU Temp**, **Uptime**, **Time Sync**, **Watchdog**

  The board is computed inside the manager with unprivileged reads only, so it
  adds no new access. (The two session-only boot checks — Display Mode and Audio
  — are intentionally omitted, since the locked service user can't assess them.)

---

# HTTPS & Access-Token Rotation

The Kiosk Manager is protected by a single **access token** that
rides in the link (`https://kiosk.example.org/?token=…`). Anyone with the link
can manage the display, so two things matter:

1. **Serve it over HTTPS** so the token isn't sniffable on the network and
   isn't written to logs in the clear.
2. **Be able to rotate the token** the moment a link leaks (a volunteer leaves,
   a screenshot gets shared, etc.) — rotating invalidates every existing link.

This guide covers both. Do **HTTPS first** — rotating a token you're still
shipping over plain HTTP just re-leaks the new one.

---

## 1. HTTPS with Let's Encrypt (DNS-01)

We use the **DNS-01** challenge, which proves you control the domain by adding a
DNS TXT record. Unlike HTTP-01, it does **not** require the Pi to be reachable
from the public internet — perfect for a kiosk that only lives on the church
LAN. Volunteers reach it by a domain name (e.g. `kiosk.example.org`) that
resolves to the Pi's LAN IP, and the browser sees a fully trusted cert with no
warnings and nothing to install on each device.

### Prerequisites

- A **domain you control** (e.g. `kiosk.example.org`).
- A DNS record pointing that name at the Pi's LAN IP. If the Pi is LAN-only,
  use a *split-horizon* / internal DNS entry, or a public `A` record pointing
  at a private IP (that's fine — DNS-01 doesn't need the record to be routable,
  only the TXT challenge record during issuance).
- `certbot` and, ideally, the certbot **DNS plugin for your provider** on the
  Pi. For Cloudflare:

  ```bash
  sudo apt-get install certbot python3-certbot-dns-cloudflare
  # store an API token scoped to DNS-edit for the zone:
  sudo install -m 0600 /dev/stdin /etc/letsencrypt/cloudflare.ini <<'EOF'
  dns_cloudflare_api_token = YOUR_SCOPED_TOKEN
  EOF
  ```

### Run it

From your workstation:

```bash
make setup-web-tls HOST=displaypi DOMAIN=kiosk.example.org EMAIL=av@church.org \
  CERTBOT_ARGS="--dns-cloudflare --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini"
```

Or directly on the Pi:

```bash
sudo DOMAIN=kiosk.example.org EMAIL=av@church.org \
     CERTBOT_ARGS="--dns-cloudflare --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini" \
     bash install/kiosk-web-tls-setup.sh
```

The script:

- obtains the cert via DNS-01,
- writes an HTTPS nginx server block (with an HTTP→HTTPS redirect and HSTS) to
  `/etc/nginx/kiosk-web-site.d/site.conf`,
- sets `PUBLIC_URL=https://kiosk.example.org` in `/etc/kiosk-web.conf` so the
  manager's shareable links and downloadable shortcuts use the canonical HTTPS
  address,
- installs a renewal deploy-hook that reloads nginx after each auto-renewal,
- runs `nginx -t` and reloads.

> **No DNS plugin?** Omit `CERTBOT_ARGS` and the script falls back to certbot's
> interactive `--manual` DNS challenge. That works, but the cert **will not
> auto-renew** — you'd have to re-run the script every ~90 days. For a
> set-and-forget kiosk, use a provider plugin.

### Why this survives redeploys

`deploy.sh` overwrites `/etc/nginx/nginx.conf` from the repo on every deploy. So
the domain-specific TLS block deliberately lives **outside** that file, in a
wildcard include (`include /etc/nginx/kiosk-web-site.d/*.conf;`). Deploying the
repo never touches your generated TLS site block.

---

## 2. Rotating the access token

Open the manager and use the **Access Link** card:

- **Copy** — copies the current link to your clipboard.
- **.webloc / .url** — downloads a double-click shortcut for Mac / Windows &
  Linux, always generated from the *current* token.
- **Rotate Token** — generates a brand-new token, **immediately invalidating
  every existing link and shortcut**, and re-keys the page you're on (no
  logout). Re-share the new link or hand out a freshly downloaded shortcut.

### How it works under the hood

The live token is stored in `/var/lib/kiosk-web/token` (`0600`, owned by the
locked `kiosk-web` service user), written atomically on rotation. The
`TOKEN=` value in `/etc/kiosk-web.conf` is only a **one-time seed** used until
the first rotation. This means rotation needs **no extra privilege**: the
service simply owns its own state directory rather than being granted write
access to root's config. The token is compared in constant time and is kept out
of nginx's access log by a query-stripping log format.

### When to rotate

- A volunteer with the link stops serving.
- The link was shared somewhere it shouldn't have been (screenshot, email, chat).
- Routine hygiene — say, at the start of a new ministry season.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `nginx -t` fails after TLS setup | The site block was written but nginx was **not** reloaded. Read the error, fix `/etc/nginx/kiosk-web-site.d/site.conf`, then `sudo systemctl reload nginx`. |
| Browser still shows the old cert | `sudo systemctl reload nginx`; hard-refresh. |
| Link works on `http://` too | Expected only until TLS setup runs; afterward `:80` 301-redirects to `:443`. |
| Downloaded shortcut points at an IP, not the domain | `PUBLIC_URL` isn't set — re-run `setup-web-tls`, or set `PUBLIC_URL=https://your.domain` in `/etc/kiosk-web.conf` and `sudo systemctl restart kiosk-web`. |
