# Splash rotation folder

Images dropped here are the **rotation set** for the kiosk's idle splash. On
`make deploy` they sync to `/home/kiosk/splash.d/` on the Pi, and `player.sh`
cycles through them — advancing **one image each time the splash is (re)entered**
(i.e. when the stream drops and the splash comes back up). There is no timer; a
single continuous idle period shows one image until the stream toggles.

## Conventions

- **Order is deterministic by filename.** Prefix with `01-`, `02-`, … to control
  the sequence.
- **Format:** 1920×1080 PNG, JPG, GIF, or WebP to match the display; mpv
  letterboxes anything off-aspect. Animated GIF/WebP plays and loops (mpv
  treats animated images as video, and the player already passes `--loop`).
- **`*-volunteer.png` is reserved.** The volunteer "replace splash" SSH pipeline
  writes `00-volunteer.png` directly into `/home/kiosk/splash.d/` on the Pi, and
  `deploy.sh` excludes `*-volunteer.png` from its `--delete` sync so a deploy
  never wipes the volunteer's slide. Don't commit a `*-volunteer.png` here.

## Fallback

If this folder ends up empty on the Pi, `player.sh` falls back to the single
`/home/kiosk/splash.png` (seeded from `images/splash.png`).
