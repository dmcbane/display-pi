---
title: Splash Image Guide — display-pi
description: How a volunteer replaces the worship display splash image shown before the stream goes live.
---

# Replacing the Worship Display Splash Image

> **Most volunteers should use the [web manager](web-manager-https.html)
> instead** — one bookmarked link, no files to keep, works from a phone. This
> guide covers the older **SSH-bundle** method, kept as an offline fallback for
> when a browser or network access to the manager isn't available.

The splash image is the background shown on the worship display before
the service stream goes live (and during any breaks). This guide walks
you through replacing that image with one of your own.

You should have received three files from the church AV admin:

| File | What it is |
|---|---|
| `splash-replace.sh` | The "do it" script for **Mac** or **Linux** |
| `splash-replace.ps1` | The "do it" script for **Windows** |
| `splash-updater` | A key file that lets your computer talk to the display |

Keep these three files **together in one folder**. The scripts look for
the key file in the same folder as themselves.

---

## Before you start: the image rules

Your image must be:

- **Exactly 1920 × 1080 pixels** (also called "Full HD" or "1080p")
- **PNG, JPEG, GIF, or WebP format** (not HEIC, BMP, etc.)
- **Under 10 MB** (most images are well under this)

If your image doesn't match these rules, the script will tell you which
one is wrong and stop without changing anything. **Nothing on the
display changes until your image passes all the checks.**

> **Why these rules?** The display is exactly 1920×1080 pixels. An image
> of the wrong size would be stretched or cropped on screen, and the
> Pi only knows how to read those four file formats.

---

## One-time setup

### On a Mac or Linux computer

1. Open the **Terminal** application.
   - **Mac:** ⌘ + Space, type "Terminal", press Enter.
   - **Linux:** Look for "Terminal" in your application menu.

2. Move to the folder containing the three files. If they're in your
   **Downloads** folder, type:

   ```
   cd ~/Downloads
   ```

3. Make the script and key file usable:

   ```
   chmod +x splash-replace.sh
   chmod 600 splash-updater
   ```

   (No output means it worked — that's normal.)

### On a Windows computer

You don't need to do anything once. Just follow the "Each time you want
to change the splash" section below.

---

## Each time you want to change the splash

### On a Mac or Linux computer

1. Save your new image as a PNG, JPEG, GIF, or WebP file. The filename
   doesn't matter — the script doesn't care what you call it.

2. Open the **Terminal** and `cd` to the folder with the three files
   (same as the setup step above).

3. Run:

   ```
   ./splash-replace.sh /path/to/your-new-image.png
   ```

   The easiest way to type the path is to **drag the image file from
   Finder/Files into the Terminal window** — your computer fills in the
   full path for you. So you can type `./splash-replace.sh ` (note the
   trailing space) then drag your image in.

### On a Windows computer

1. Save your new image as a PNG, JPEG, GIF, or WebP file anywhere.

2. **Right-click** on `splash-replace.ps1` and choose **"Run with
   PowerShell"**.

3. A blue window will open and ask for the path to your image. Type or
   paste it.

   *(Alternative if right-click doesn't show "Run with PowerShell":
   open PowerShell from the Start menu, navigate to the folder using
   `cd C:\path\to\bundle`, then run
   `.\splash-replace.ps1 C:\path\to\your-image.png`.)*

---

## What you should see when it works

```
[splash-replace] file looks good (1920x1080 PNG)
[splash-replace] uploading to displaypi...
OK: splash replaced (1920x1080 PNG, 987395 bytes)
```

(For a JPEG or WebP image the first line instead says the display will
verify the size when it arrives — that's normal.)

About 2 seconds after the "OK" line, the display in the sanctuary will
go dark for a moment then come back showing your new image.

---

## Common errors and what they mean

| Message you see | What's wrong | What to do |
|---|---|---|
| `not a PNG, JPEG, GIF, or WebP file` | Unsupported format (HEIC, BMP, …) | Open it in your editor and "Save As" / "Export As" PNG or JPEG |
| `must be exactly 1920x1080` | Wrong dimensions | Resize your image to 1920×1080 and try again |
| `file too large` | Image is over 10 MB | Re-export at a slightly lower quality setting |
| `file not found` | Typo in the path | Drag the image into Terminal/PowerShell instead of typing |
| `SSH key not found` | The `splash-updater` file isn't next to the script | Put it in the same folder as the script |
| `Permission denied (publickey)` | Wrong key, or admin removed your access | Contact the admin |
| `Connection refused` or `No route to host` | Not on the church network, or display Pi is off | Make sure you're on the church Wi-Fi and the Pi is plugged in |
| `Connection timed out` | Same as above | Same as above |

---

## Security notes (please read)

The `splash-updater` key file is what proves to the display that you're
allowed to change the splash. Please:

- **Don't share it.** If you need to give the bundle to someone else,
  ask the admin to make them their own bundle.
- **Don't email it to yourself.** Email isn't encrypted by default —
  if you need to move it between machines, use a USB stick or a
  password-protected file share.
- **If you think the key file has been seen by someone outside the
  church AV team, tell the admin immediately.** They can revoke the
  key and issue a new one in a few minutes.

The display is set up so that even if someone gets the key file, the
**only** thing they can do with it is replace the splash image with
another valid 1920×1080 image. They cannot get into the display, read
files, change settings, or stop the worship stream — the key only
opens that one specific door.

---

## When in doubt

Contact the church AV admin. Send them:

1. The exact command you typed
2. The exact text the script printed back at you
3. A copy of the image file you were trying to upload

This is usually enough to diagnose the problem without a phone call.
