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

export KIOSK_HOST  := $(HOST)
export KIOSK_USER
export STREAM_KEY

.PHONY: deploy sudoers test-stream test-stream-long ssh logs status diag test lint check

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

# --- Convenience ---

ping:
	@ping -c 3 $(HOST)

reboot:
	@echo "Rebooting $(HOST)..."
	@ssh $(HOST) "sudo reboot" || true
	@echo "Reboot command sent. Pi will come back in ~30s."
