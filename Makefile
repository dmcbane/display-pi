# display-pi — Church Worship Stream Kiosk
#
# Usage:
#   make deploy              Deploy to Pi and restart kiosk
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

.PHONY: deploy test-stream test-stream-long ssh logs status diag test lint check

# --- Deployment ---

deploy:
	@./dev/deploy.sh $(HOST)

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
