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

This guide covers both. HTTPS is **on by default** — `make setup-web` issues a
locally-signed certificate — so for the common case there's nothing extra to set
up; jump to [token rotation](#2-rotating-the-access-token) if you don't need a
publicly-trusted cert.

---

## 1. HTTPS

### The default: a locally-signed certificate

`make setup-web` (and `make provision`) bring the manager up over HTTPS using a
certificate **signed by a small certificate authority generated on the Pi
itself** — no domain, no DNS, no internet. Volunteers reach the manager at
`https://displaypi/` (or `https://displaypi.local/`, or by IP); the cert covers
the hostname, `<hostname>.local`, and every LAN address.

Because the CA is your own, browsers don't trust it until you say so. **Once per
device** that manages the kiosk:

1. Download the Pi's root CA — it's served over plain HTTP so a fresh device can
   fetch it before it trusts anything:

   ```
   http://displaypi/rootCA.crt
   ```

   (or run `make web-ca HOST=displaypi` on your workstation, which saves
   `display-pi-rootCA.crt`).
2. **Import it as a trusted root / certificate authority** on the device
   (macOS: Keychain → System, set to *Always Trust*; Windows: *Install
   Certificate → Trusted Root Certification Authorities*; Android: *Settings →
   Security → Install a certificate → CA certificate*; iOS: install the profile,
   then enable it under *Settings → General → About → Certificate Trust
   Settings*).

After that the device shows a normal padlock with no warning. A device that
hasn't imported the CA still works — it just shows the usual "not trusted" prompt
first. (HSTS is only ever seen *after* a successful TLS handshake, so it can
never lock out a device that doesn't trust the CA.)

The root CA is **stable across re-runs**, so trust you've installed keeps
working. The **server** cert is re-issued each run, which picks up a changed
hostname or DHCP address — so after the Pi's IP changes, run:

```bash
make setup-web-tls-local HOST=displaypi
```

### Alternative: a publicly-trusted Let's Encrypt cert

If you control a **domain**, you can skip the per-device CA import with a
Let's Encrypt certificate via the **DNS-01** challenge (the Pi never needs to be
reachable from the public internet — you only need control of the domain's DNS):

```bash
make setup-web-tls HOST=displaypi DOMAIN=kiosk.example.org EMAIL=av@church.org \
  CERTBOT_ARGS="--dns-cloudflare --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini"
```

`CERTBOT_ARGS` holds your DNS provider's certbot plugin flags (install e.g.
`python3-certbot-dns-cloudflare` first). It sets `PUBLIC_URL=https://<domain>`,
adds an HTTP→HTTPS redirect + HSTS, and installs a renewal hook that reloads
nginx after each auto-renewal. Omit `CERTBOT_ARGS` to fall back to certbot's
interactive `--manual` DNS challenge — that works but **won't auto-renew**, so
you'd re-run it every ~90 days.

### Why this survives redeploys

`deploy.sh` overwrites `/etc/nginx/nginx.conf` from the repo on every deploy. So
the TLS site block deliberately lives **outside** that file, in a wildcard
include (`include /etc/nginx/kiosk-web-site.d/*.conf;`). Deploying the repo never
touches your generated TLS site block or certificates.

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
| "Not secure" / "certificate not trusted" warning | The device hasn't imported this Pi's root CA yet — download `http://<pi>/rootCA.crt` (or `make web-ca`) and install it as a trusted root. Or use the Let's Encrypt path for a publicly-trusted cert. |
| Padlock breaks after the Pi's IP changed | The server cert's addresses are stale — re-issue it: `make setup-web-tls-local HOST=<pi>` (your imported CA still works; no re-import needed). |
| `nginx -t` fails after TLS setup | The site block was written but nginx was **not** reloaded. Read the error, fix `/etc/nginx/kiosk-web-site.d/site.conf`, then `sudo systemctl reload nginx`. |
| Browser still shows the old cert | `sudo systemctl reload nginx`; hard-refresh. |
| Link works on `http://` too | `:80` only serves `/rootCA.crt`; everything else 301-redirects to `:443`. |
| Downloaded shortcut points at an IP, not the domain | `PUBLIC_URL` isn't set — re-run `setup-web-tls`, or set `PUBLIC_URL=https://your.domain` in `/etc/kiosk-web.conf` and `sudo systemctl restart kiosk-web`. |
