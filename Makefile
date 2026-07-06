# display-pi — Church Worship Stream Kiosk
#
# Usage:
#   make deploy              Deploy to Pi and restart kiosk
#   make sudoers             One-time: install deploy sudoers whitelist on Pi
#                            (interactive — prompts for sudo password once)
#   make test-stream         Send 60s test pattern to Pi
#   make test-stream-long    Send 5min test pattern to Pi
#   make ssh                 Interactive shell on Pi
#   make logs                Tail kiosk + nginx logs
#   make status              Show kiosk service status
#   make diag                Run diagnostics on Pi (text output)
#   make test                Run local tests
#
# Override the Pi hostname:
#   make deploy HOST=192.168.0.106

HOST       ?= displaypi
KIOSK_USER ?= kiosk
STREAM_KEY ?= restoration

# Setup-only defaults (consumed by `make setup`). Match install/setup-kiosk.sh.
RTMP_APP                 ?= live
PLAYBACK_VOLUME          ?= 80
SPLASH_TEXT              ?= Service will begin shortly
RTMP_ALLOW_PUBLISH_CIDRS ?= 192.168.0.0/16 10.0.0.0/8

# HDMI mode forced via the kernel video= parameter in cmdline.txt.
# Empty/unset = let EDID pick. Use `make hdmi-mode HDMI_MODE=...` after
# initial setup to change it without re-running full setup.
HDMI_MODE                ?=

# Extra static IPv4 address bound to Ethernet alongside DHCP, so the Pi is
# reachable on networks without a DHCP server (setup only). Format
# "<addr>/<prefix>", e.g. 192.168.50.1/24. Empty = DHCP only; "none" removes
# a static IP added by a previous run.
STATIC_IP                ?=

# Optional gateway / DNS for the static profile (setup only). Leave empty when
# STATIC_IP is just a direct-reach extra address (DHCP owns the routes). Set
# when the static address is the Pi's primary identity on a DHCP-less network.
# STATIC_DNS is comma-separated (nmcli syntax), e.g. 192.168.0.1,1.1.1.1.
STATIC_GATEWAY           ?=
STATIC_DNS               ?=

# System-wide default locale for the Pi (setup only). Generated and set as the
# default, and stripped from sshd's AcceptEnv so a login never shows the
# "cannot change locale" warning regardless of what the client forwards. Match
# your region if not US English (e.g. en_GB.UTF-8).
DISPLAY_LOCALE           ?= en_US.UTF-8

# Optional seconds-of-offset added to the laptop clock when pushing time
# to the Pi (consumed by `make set-time`). Positive = anticipate SSH lag.
TIME_OFFSET              ?= 0

# SSH password-login state for `make ssh-password`. on = allow public key OR
# password; off = key-only; status = just report (the safe default).
STATE                    ?= status

export KIOSK_HOST  := $(HOST)
export KIOSK_USER
export STREAM_KEY

.PHONY: help setup provision deploy sudoers test-stream test-stream-long ssh ssh-password logs status diag judder-tree judder-probe judder-monitor stream-key hdmi-mode set-time test lint check ping reboot restart shutdown volunteer-bundle setup-web setup-web-tls-local web-ca setup-web-tls volunteer-web-url

help:
	@echo "display-pi — Church Worship Stream Kiosk"
	@echo ""
	@echo "Bootstrap:"
	@echo "  provision         New kiosk, end to end: setup + deploy + setup-web + volunteer-web-url"
	@echo "  setup             First-time Pi setup only (creates kiosk user, installs services)"
	@echo ""
	@echo "Deployment:"
	@echo "  deploy            Sync repo to Pi and restart kiosk service"
	@echo ""
	@echo "Testing:"
	@echo "  test-stream       Send 60s test pattern to Pi"
	@echo "  test-stream-long  Send 5min test pattern to Pi"
	@echo "  test              Run local tests"
	@echo "  lint              Run shellcheck on shell scripts"
	@echo "  check             Run lint + test"
	@echo ""
	@echo "Remote operations:"
	@echo "  ssh               Interactive shell on Pi"
	@echo "  ssh-password      Toggle SSH password login (STATE=on|off|status)"
	@echo "  logs              Tail kiosk + nginx logs"
	@echo "  status            Show kiosk service status"
	@echo "  diag              Run diagnostics on Pi"
	@echo "  judder-tree       Print judder decision tree (offline-friendly)"
	@echo "  judder-probe      One-shot judder probe on Pi"
	@echo "  judder-monitor    Rolling judder sampler on Pi (Ctrl-C to stop)"
	@echo "  stream-key        Print stream key any active publisher is using"
	@echo "  hdmi-mode         Set/clear HDMI mode (HDMI_MODE=1920x1080@30 or 'none')"
	@echo "  set-time          Push laptop clock to Pi (optional TIME_OFFSET=<sec>)"
	@echo "  ping              Ping the Pi"
	@echo "  reboot            Reboot the Pi"
	@echo "  restart           Restart the kiosk service (advances splash rotation)"
	@echo "  shutdown          Shutdown the Pi"
	@echo ""
	@echo "Volunteer workflow:"
	@echo "  setup-web            One-time: install web manager on Pi (HTTPS via local cert by default)"
	@echo "  setup-web-tls-local  (Re)issue the local HTTPS cert (e.g. after an IP change)"
	@echo "  web-ca               Fetch the Pi's root CA to import on devices (warning-free padlock)"
	@echo "  setup-web-tls        Alternative HTTPS: Let's Encrypt DNS-01 (needs DOMAIN=)"
	@echo "  volunteer-web-url    Generate volunteer URL shortcut files (.webloc / .url)"
	@echo "  volunteer-bundle  Build volunteer-bundle.zip (legacy SSH scripts + key)"
	@echo ""
	@echo "Variables (override on command line):"
	@echo "  HOST=$(HOST)"
	@echo "      Pi hostname or IP"
	@echo "  KIOSK_USER=$(KIOSK_USER)"
	@echo "      Remote user that runs the kiosk"
	@echo "  STREAM_KEY=$(STREAM_KEY)"
	@echo "      RTMP stream key (used by setup and test-stream)"
	@echo "  RTMP_APP=$(RTMP_APP)"
	@echo "      RTMP application path component (setup only)"
	@echo "  PLAYBACK_VOLUME=$(PLAYBACK_VOLUME)"
	@echo "      mpv volume 0-100 (setup only)"
	@echo "  SPLASH_TEXT='$(SPLASH_TEXT)'"
	@echo "      Text on the placeholder splash image (setup only)"
	@echo "  RTMP_ALLOW_PUBLISH_CIDRS='$(RTMP_ALLOW_PUBLISH_CIDRS)'"
	@echo "      Space-separated CIDRs allowed to push RTMP (setup only)"
	@echo "  HDMI_MODE='$(HDMI_MODE)'"
	@echo "      Force HDMI mode via cmdline.txt video= (e.g. 1920x1080@30)."
	@echo "      Empty = let display pick. Used by 'setup' and 'hdmi-mode'."
	@echo "  STATIC_IP='$(STATIC_IP)'"
	@echo "      Extra static IP on Ethernet alongside DHCP (setup only),"
	@echo "      e.g. 192.168.50.1/24. Empty = DHCP only; 'none' removes it."
	@echo "      Applies on reboot (or: sudo nmcli connection up kiosk-static)."
	@echo "  STATIC_GATEWAY='$(STATIC_GATEWAY)'"
	@echo "      Optional gateway for the static profile (setup only). Leave"
	@echo "      empty for a direct-reach extra address (DHCP owns routes)."
	@echo "  STATIC_DNS='$(STATIC_DNS)'"
	@echo "      Optional DNS for the static profile, comma-separated (setup only)."
	@echo "  DISPLAY_LOCALE=$(DISPLAY_LOCALE)"
	@echo "      System default locale (setup only). Stops the 'cannot change"
	@echo "      locale' SSH login warning. Match your region, e.g. en_GB.UTF-8."
	@echo "  TIME_OFFSET=$(TIME_OFFSET)"
	@echo "      Seconds to add to the laptop clock when running 'set-time'."
	@echo "      Use a small positive value (e.g. 1.0) to compensate for SSH lag."
	@echo ""
	@echo "Examples:"
	@echo "  make provision STREAM_KEY=mykey HOST=192.168.0.106"
	@echo "  make deploy HOST=192.168.0.106"
	@echo "  make setup STREAM_KEY=mykey RTMP_ALLOW_PUBLISH_CIDRS='192.168.1.42/32'"
	@echo "  make setup STATIC_IP=192.168.50.1/24    # reach the Pi with no DHCP"
	@echo "  make hdmi-mode HDMI_MODE=1920x1080@30"
	@echo "  make set-time TIME_OFFSET=1.0"

# --- Bootstrap ---

# One-time setup: rsync the repo to the SSH user's home and run setup-kiosk.sh.
# Use this on a fresh Pi before `make deploy`. setup-kiosk.sh is idempotent,
# so re-running is safe.
#
# Only variables you explicitly set (command line or environment) are
# forwarded to the Pi — $(origin) distinguishes them from Makefile defaults.
# Anything not forwarded keeps its persisted value from a previous setup
# (/etc/default/kiosk on the Pi), so `make setup HDMI_MODE=…` months after
# `make provision STREAM_KEY=mykey` cannot silently reset the stream key.
SETUP_FWD_VARS := KIOSK_USER STREAM_KEY RTMP_APP PLAYBACK_VOLUME SPLASH_TEXT \
    RTMP_ALLOW_PUBLISH_CIDRS HDMI_MODE STATIC_IP STATIC_GATEWAY STATIC_DNS \
    DISPLAY_LOCALE
SETUP_ENV = $(foreach v,$(SETUP_FWD_VARS),$(if $(filter command line environment%,$(origin $(v))),$(v)='$($(v))'))

setup:
	@echo "Bootstrapping $(HOST)..."
	@rsync -avz \
	    --exclude='.git/' \
	    --exclude='.claude/' \
	    --exclude='*.swp' \
	    --exclude='*.swo' \
	    --exclude='__pycache__/' \
	    ./ $(HOST):display-pi-bootstrap/
	@ssh -t $(HOST) "cd display-pi-bootstrap && \
	    $(SETUP_ENV) \
	    bash install/setup-kiosk.sh"

# One command to take a fresh Pi all the way to a working, volunteer-managed
# kiosk. Runs the four one-time steps IN ORDER — the order is load-bearing:
#   1. setup             bootstrap the base kiosk (creates kiosk user/services)
#   2. deploy            create the canonical /home/$(KIOSK_USER)/display-pi repo
#   3. setup-web         install the volunteer web manager (reads from #2's path)
#   4. volunteer-web-url generate the .webloc/.url shortcut files (hold the token)
# Each step is a recursive $(MAKE) so the sequence holds even under `make -j`,
# and command-line overrides (HOST, STREAM_KEY, …) propagate to every step.
# Every step is idempotent, so re-running provision on an existing Pi is safe.
provision:
	@echo "[provision] New-kiosk setup on $(HOST): setup -> deploy -> setup-web -> volunteer-web-url"
	@$(MAKE) setup
	@$(MAKE) deploy
	@$(MAKE) setup-web
	@$(MAKE) volunteer-web-url
	@echo "[provision] Done. $(HOST) is provisioned; volunteer shortcut files written."

# --- Deployment ---

deploy:
	@./dev/deploy.sh $(HOST)

# One-time bootstrap: install the deploy sudoers whitelist on an existing
# Pi. Interactive (prompts once for the Pi sudo password). After this
# completes, `make deploy` runs without password prompts. New Pis get the
# same whitelist automatically via setup-kiosk.sh.
sudoers:
	@DEPLOY_USER=$$(ssh $(HOST) whoami); \
	echo "[sudoers] Installing /etc/sudoers.d/kiosk-deploy on $(HOST) for user $$DEPLOY_USER..."; \
	scp install/kiosk-deploy.sudoers $(HOST):/tmp/kiosk-deploy.sudoers.in; \
	ssh -t $(HOST) "sed 's/__DEPLOY_USER__/$$DEPLOY_USER/g' /tmp/kiosk-deploy.sudoers.in > /tmp/kiosk-deploy.sudoers \
	    && sudo visudo -cf /tmp/kiosk-deploy.sudoers \
	    && sudo install -o root -g root -m 0440 /tmp/kiosk-deploy.sudoers /etc/sudoers.d/kiosk-deploy \
	    && rm -f /tmp/kiosk-deploy.sudoers /tmp/kiosk-deploy.sudoers.in"; \
	echo "[sudoers] Done. Future deploys will not prompt for a password."

# --- Testing ---

test-stream:
	@./dev/test-stream.sh $(HOST) 60

test-stream-long:
	@./dev/test-stream.sh $(HOST) 300

test:
	@./tests/run-tests.sh

lint:
	@echo "Checking shell scripts with shellcheck..."
	@shellcheck install/*.sh diagnostics/*.sh dev/*.sh tests/*.sh 2>/dev/null || \
		echo "shellcheck not installed — install with: apt install shellcheck"

check: lint test

# --- Remote operations ---

ssh:
	@./dev/pi-shell.sh $(HOST) shell

# Allow SSH login by public key OR password (STATE=on), flip back to
# key-only (STATE=off), or just report the effective setting (STATE=status,
# the default). Pubkey auth always stays enabled, so STATE=off can't lock
# out key-based logins. The toggle validates with `sshd -t` and applies via
# reload, so the live SSH session survives. Runs the deployed copy of the
# script as root on the Pi (prompts once for the Pi sudo password).
#   make ssh-password STATE=on
#   make ssh-password STATE=off
#   make ssh-password               # STATE=status
ssh-password:
	@case "$(STATE)" in on|off|status) ;; *) \
	    echo "ERROR: STATE must be on, off, or status (got '$(STATE)')"; exit 2 ;; esac
	@ssh -t $(HOST) "sudo bash /home/$(KIOSK_USER)/display-pi/install/sshd-password-toggle.sh $(STATE)"

logs:
	@./dev/pi-shell.sh $(HOST) logs

status:
	@./dev/pi-shell.sh $(HOST) status

diag:
	@./dev/pi-shell.sh $(HOST) diag

judder-tree:
	@./diagnostics/judder.sh tree

judder-probe:
	@ssh $(HOST) "sudo -u $(KIOSK_USER) /home/$(KIOSK_USER)/display-pi/diagnostics/judder.sh probe"

judder-monitor:
	@ssh -t $(HOST) "sudo -u $(KIOSK_USER) /home/$(KIOSK_USER)/display-pi/diagnostics/judder.sh monitor"

# Fast one-shot lookup of what stream key the publisher is currently using.
# Useful during a live event when the kiosk is on splash and you need to know
# whether to fix the publisher or hot-edit STREAM_URL on the Pi.
stream-key:
	@ssh $(HOST) "sudo -u $(KIOSK_USER) /home/$(KIOSK_USER)/display-pi/diagnostics/judder.sh stream-key"

# Apply (or clear) an HDMI mode on an already-deployed Pi. KMS-correct
# path: edits cmdline.txt, idempotent, prompts for reboot.
#   make hdmi-mode HDMI_MODE=1920x1080@30
#   make hdmi-mode HDMI_MODE=none           # clear forcing
hdmi-mode:
	@if [ -z "$(HDMI_MODE)" ]; then \
	    echo "ERROR: HDMI_MODE not set. Examples:"; \
	    echo "  make hdmi-mode HDMI_MODE=1920x1080@30"; \
	    echo "  make hdmi-mode HDMI_MODE=none"; \
	    exit 2; \
	fi
	@./dev/set-hdmi-mode.sh $(HOST) $(HDMI_MODE)

# Push the laptop's clock to the Pi over SSH. Handy at offline venues
# where the Pi (no RTC) has drifted and systemd-timesyncd has no upstream.
# TIME_OFFSET (seconds) is added to the laptop clock to anticipate the SSH
# round-trip lag so the Pi's wall clock lands on the intended time, not
# OFFSET-seconds behind it. Requires the Pi's sudo password (intentional —
# `date -s` is not in the deploy sudoers whitelist).
#   make set-time
#   make set-time TIME_OFFSET=1.0
set-time:
	@./dev/set-pi-time.sh $(HOST) $(TIME_OFFSET)

# --- Convenience ---

ping:
	@ping -c 3 $(HOST)

reboot:
	@echo "Rebooting $(HOST)..."
	@ssh $(HOST) "sudo reboot" || true
	@echo "Reboot command sent. Pi will come back in ~30s."

shutdown:
	@echo "Shutting down $(HOST)..."
	@ssh $(HOST) "sudo poweroff" || true
	@echo "Shutdown command sent. Pi will poweroff."


# Restart the kiosk service without a full deploy. Handy during testing: the
# player re-enters the splash loop on restart, so each `make restart` advances
# the splash rotation by one image (when the stream is idle). Uses the same
# password-free `sudo -u kiosk` path as `make deploy` (deploy sudoers
# whitelist), so it won't prompt. Single-quoted so the Pi resolves the kiosk
# UID, not the workstation.
restart:
	@echo "Restarting kiosk service on $(HOST)..."
	@ssh $(HOST) 'sudo -u $(KIOSK_USER) XDG_RUNTIME_DIR="/run/user/$$(id -u $(KIOSK_USER))" systemctl --user restart kiosk.service'
	@echo "Kiosk service restarted on $(HOST)."

# --- Volunteer bundle ---

# Build volunteer-bundle.zip containing the two client scripts, the
# README, and the splash-updater private key (pulled live from the
# Pi). The bundle is what you hand to a volunteer over USB stick or a
# trusted file-share — never email it: the key is inside.
#
# Prereqs:
#   - install/splash-updater-setup.sh must have been run on the Pi
#     once (creates /etc/ssh/splash-updater_ed25519 and the user).
#   - `zip` available on the workstation.
#
# Output: ./volunteer-bundle.zip (overwritten each run).
volunteer-bundle:
	@command -v zip >/dev/null || { echo "ERROR: 'zip' not installed (try: apt install zip)"; exit 1; }
	@echo "[volunteer-bundle] staging files..."
	@rm -rf /tmp/splash-bundle volunteer-bundle.zip
	@mkdir -p /tmp/splash-bundle
	@cp dev/splash-replace.sh dev/splash-replace.ps1 /tmp/splash-bundle/
	@cp docs/volunteer-splash-update.md /tmp/splash-bundle/README.md
	@echo "[volunteer-bundle] pulling private key from $(HOST):/etc/ssh/splash-updater_ed25519..."
	@ssh $(HOST) 'sudo cat /etc/ssh/splash-updater_ed25519' > /tmp/splash-bundle/splash-updater
	@chmod 600 /tmp/splash-bundle/splash-updater
	@chmod 755 /tmp/splash-bundle/splash-replace.sh
	@cd /tmp/splash-bundle && zip -q ../../$(CURDIR)/volunteer-bundle.zip splash-replace.sh splash-replace.ps1 README.md splash-updater
	@rm -rf /tmp/splash-bundle
	@echo "[volunteer-bundle] wrote $(CURDIR)/volunteer-bundle.zip"
	@unzip -l volunteer-bundle.zip | sed 's/^/    /'
	@echo ""
	@echo "Hand-deliver this zip on a USB stick. Do NOT email it — the SSH"
	@echo "private key inside is what proves the holder is authorized to"
	@echo "replace the splash."

# --- Volunteer web manager ---

# One-time setup: install the web manager on the Pi (requires internet on Pi
# for the first `pip install flask pillow`). Brings the manager up over HTTPS
# with a locally-signed cert by default. Safe to re-run.
setup-web:
	@echo "Setting up kiosk-web on $(HOST)..."
	@ssh -t $(HOST) "sudo bash /home/$(KIOSK_USER)/display-pi/install/kiosk-web-setup.sh"

# (Re)issue the local HTTPS cert — e.g. after the Pi's IP changes, or to switch
# an existing HTTP/Let's Encrypt install to a locally-signed cert. No domain
# needed. Override the shareable-link host with PUBLIC_HOST=.
setup-web-tls-local:
	@echo "Issuing a locally-signed HTTPS cert for kiosk-web on $(HOST)..."
	@ssh -t $(HOST) "sudo PUBLIC_HOST='$(PUBLIC_HOST)' \
	    bash /home/$(KIOSK_USER)/display-pi/install/kiosk-web-tls-local.sh"

# Fetch this Pi's root CA so you can import it on devices (one-time) for a
# warning-free padlock. Writes display-pi-rootCA.crt to the current directory.
web-ca:
	@curl -fsS "http://$(HOST)/rootCA.crt" -o display-pi-rootCA.crt \
	    && echo "[web-ca] wrote display-pi-rootCA.crt — import it as a trusted root on each device." \
	    || echo "[web-ca] ERROR: could not fetch http://$(HOST)/rootCA.crt (is the local-cert HTTPS set up?)"

# Alternative HTTPS path: a publicly-trusted Let's Encrypt DNS-01 cert (no
# per-device CA import), for when you control a domain. Pass DOMAIN (and ideally
# CERTBOT_ARGS for your DNS plugin so the cert auto-renews). See docs/web-manager-https.md.
#   make setup-web-tls HOST=displaypi DOMAIN=kiosk.church.org EMAIL=av@church.org \
#     CERTBOT_ARGS="--dns-cloudflare --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini"
setup-web-tls:
	@if [ -z "$(DOMAIN)" ]; then echo "ERROR: set DOMAIN=your.kiosk.domain"; exit 1; fi
	@echo "Enabling HTTPS ($(DOMAIN)) for kiosk-web on $(HOST)..."
	@ssh -t $(HOST) "sudo DOMAIN='$(DOMAIN)' EMAIL='$(EMAIL)' CERTBOT_ARGS='$(CERTBOT_ARGS)' \
	    bash /home/$(KIOSK_USER)/display-pi/install/kiosk-web-tls-setup.sh"

# Generate volunteer URL shortcut files from the live token on the Pi.
# Outputs volunteer-kiosk.webloc (Mac) and volunteer-kiosk.url (Windows/Linux).
# Both are gitignored — they contain the auth token.
# The LIVE token is the rotatable /var/lib/kiosk-web/token (written by the
# app on first rotation); /etc/kiosk-web.conf's TOKEN= is only the install
# seed, dead after any rotation. Prefer the store, fall back to the seed.
volunteer-web-url:
	@TOKEN=$$(ssh $(HOST) "sudo cat /var/lib/kiosk-web/token 2>/dev/null || sudo grep '^TOKEN=' /etc/kiosk-web.conf 2>/dev/null | cut -d= -f2-"); \
	if [ -z "$$TOKEN" ]; then \
	    echo "ERROR: kiosk-web not set up on $(HOST). Run: make setup-web HOST=$(HOST)"; \
	    exit 1; \
	fi; \
	BASE=$$(ssh $(HOST) "sudo grep '^PUBLIC_URL=' /etc/kiosk-web.conf 2>/dev/null | cut -d= -f2-"); \
	BASE=$${BASE:-https://$(HOST)}; \
	URL="$$BASE/?token=$$TOKEN"; \
	printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n\t<key>URL</key>\n\t<string>%s</string>\n</dict>\n</plist>\n' \
	    "$$URL" > volunteer-kiosk.webloc; \
	printf '[InternetShortcut]\nURL=%s\n' "$$URL" > volunteer-kiosk.url; \
	echo "[volunteer-web-url] URL: $$URL"; \
	echo "[volunteer-web-url] wrote volunteer-kiosk.webloc  (Mac: double-click to open)"; \
	echo "[volunteer-web-url] wrote volunteer-kiosk.url     (Windows / Linux: double-click to open)"
