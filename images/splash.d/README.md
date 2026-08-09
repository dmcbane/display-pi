# Splash rotation folder — the FIRST-INSTALL SEED

Images dropped here seed the kiosk's splash rotation **on a fresh Pi only**.

On the Pi itself, every splash image lives in one folder — the splash store,
`/var/lib/kiosk-splash` (or whatever `SPLASH_DIR` in `/etc/default/kiosk`
says). Provisioning copies this folder into the store **only when the store is
empty**. Once the Pi has images, they belong to the operator and the
volunteers, and nothing here overwrites them.

So: **editing these files and running `make deploy` will not change what a
provisioned Pi displays.** To change slides on a live Pi, use the volunteer web
manager, or `become-kiosk-web` over SSH and edit the store directly. Run
`make splash-ls HOST=…` to see the live folder and its contents.

## Conventions

- **Order is deterministic by filename.** Prefix with `01-`, `02-`, … to control
  the sequence.
- **Format:** 1920×1080 PNG, JPG, GIF, or WebP to match the display; mpv
  letterboxes anything off-aspect. Animated GIF/WebP plays and loops (mpv
  treats animated images as video, and the player already passes `--loop`).
- **`*-volunteer.*` is reserved.** The volunteer "replace splash" SSH pipeline
  writes `00-volunteer.<ext>` into the splash store on the Pi. Don't commit a
  `*-volunteer.*` here.

## If the store ends up empty

The player logs an error and displays nothing — deliberately. There is no
single-image fallback any more; a second location only ever served to hide the
fact that the real folder had gone missing. Re-seed with:

```sh
ssh <pi> 'sudo bash /home/kiosk/display-pi/install/splash-store.sh seed \
    /home/kiosk/display-pi/images/splash.d'
```
