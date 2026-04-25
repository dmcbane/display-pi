# `journalctl --user -u kiosk.service` shows no entries

Date: 2026-04-25 (recurrence; first hit was earlier)

## Symptom

On a freshly-set-up Pi, asking for kiosk service logs returns nothing
useful:

- As root: `journalctl --user -u kiosk.service` → `-- No entries --`
- As `kiosk` (with `XDG_RUNTIME_DIR=/run/user/$(id -u kiosk)`):
  `Hint: You are currently not seeing messages from the system.
   Users in groups 'adm', 'systemd-journal' can see all messages.
   No journal files were opened due to insufficient permissions.`

Service is actually running (`systemctl --user status` shows
active/running with the expected cgroup tree) — the journal just isn't
being kept.

## Root cause

systemd-journald defaults to **volatile** storage on Raspberry Pi OS:
journals live in `/run/log/journal/` (tmpfs) and are not persisted.
User journals also don't accumulate without persistent storage in place.

## Fix

Switch journald to persistent storage. Either:

- `sudo mkdir -p /var/log/journal && sudo systemctl restart systemd-journald`
  (journald auto-detects the directory and starts persisting), or
- set `Storage=persistent` in `/etc/systemd/journald.conf` and restart
  `systemd-journald`.

After this, `journalctl --user -u kiosk.service` (run as the kiosk user
with `XDG_RUNTIME_DIR` set) returns real entries.

## Follow-up worth considering

This has now bitten us at least twice on fresh Pis. `setup-kiosk.sh`
should ensure persistent journal storage so that `make logs` /
`make status` / any post-setup debugging actually has data to show.
