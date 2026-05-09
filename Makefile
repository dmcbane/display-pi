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
STREAM_KEY ?= church242

# Setup-only defaults (consumed by `make setup`). Match install/setup-kiosk.sh.
RTMP_APP                 ?= live
PLAYBACK_VOLUME          ?= 80
SPLASH_TEXT              ?= Service will begin shortly
RTMP_ALLOW_PUBLISH_CIDRS ?= 192.168.0.0/16 10.0.0.0/8

export KIOSK_HOST  := $(HOST)
export KIOSK_USER
export STREAM_KEY

.PHONY: help setup deploy sudoers test-stream test-stream-long ssh logs status diag judder-tree judder-probe judder-monitor test lint check ping reboot

help:
	@echo "display-pi — Church Worship Stream Kiosk"
	@echo ""
	@echo "Bootstrap:"
	@echo "  setup             First-time Pi setup (creates kiosk user, installs services)"
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
	@echo "  logs              Tail kiosk + nginx logs"
	@echo "  status            Show kiosk service status"
	@echo "  diag              Run diagnostics on Pi"
	@echo "  judder-tree       Print judder decision tree (offline-friendly)"
	@echo "  judder-probe      One-shot judder probe on Pi"
	@echo "  judder-monitor    Rolling judder sampler on Pi (Ctrl-C to stop)"
	@echo "  ping              Ping the Pi"
	@echo "  reboot            Reboot the Pi"
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
	@echo ""
	@echo "Examples:"
	@echo "  make deploy HOST=192.168.0.106"
	@echo "  make setup STREAM_KEY=mykey RTMP_ALLOW_PUBLISH_CIDRS='192.168.1.42/32'"

# --- Bootstrap ---

# One-time setup: rsync the repo to the SSH user's home and run setup-kiosk.sh.
# Use this on a fresh Pi before `make deploy`. setup-kiosk.sh is idempotent,
# so re-running is safe. All six setup variables (KIOSK_USER, STREAM_KEY,
# RTMP_APP, PLAYBACK_VOLUME, SPLASH_TEXT, RTMP_ALLOW_PUBLISH_CIDRS) are
# forwarded to the remote shell — see `make help`.
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
	    KIOSK_USER='$(KIOSK_USER)' \
	    STREAM_KEY='$(STREAM_KEY)' \
	    RTMP_APP='$(RTMP_APP)' \
	    PLAYBACK_VOLUME='$(PLAYBACK_VOLUME)' \
	    SPLASH_TEXT='$(SPLASH_TEXT)' \
	    RTMP_ALLOW_PUBLISH_CIDRS='$(RTMP_ALLOW_PUBLISH_CIDRS)' \
	    bash install/setup-kiosk.sh"

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

# --- Convenience ---

ping:
	@ping -c 3 $(HOST)

reboot:
	@echo "Rebooting $(HOST)..."
	@ssh $(HOST) "sudo reboot" || true
	@echo "Reboot command sent. Pi will come back in ~30s."
