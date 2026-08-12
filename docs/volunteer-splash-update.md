---
title: Splash Image Guide — display-pi
description: How a volunteer replaces the worship display splash image shown before the stream goes live, using the browser-based web manager.
---

# Replacing the Worship Display Splash Image

The splash image is the background shown on the worship display before the
service stream goes live (and during any breaks). This guide walks you through
replacing it with one of your own.

Everything happens in the **web manager** — a page you open in a browser on
your phone, tablet, or computer. There is nothing to install and no files to
keep. The AV admin will send you a link that looks like this:

```
http://displaypi/?token=…
```

Bookmark it, or save the shortcut file the admin hands you (double-click it and
the page opens). The link contains your access token, so treat it like a
password — see [Security notes](#security-notes-please-read) at the bottom.

> The full tour of the manager — status board, restart, reboot, HTTPS, token
> rotation — is in the [web manager guide](web-manager-https.html). This page
> covers just the splash images.

---

## Before you start: the image rules

Your image must be:

- **Exactly 1920 × 1080 pixels** (also called "Full HD" or "1080p")
- **PNG, JPEG, GIF, or WebP format** (not HEIC, BMP, etc.)
- **Under 10 MB** (most images are well under this)

If your image doesn't match these rules, the manager tells you which one is
wrong and stops without changing anything. **Nothing on the display changes
until your image passes all the checks.**

> **Why these rules?** The display is exactly 1920×1080 pixels. An image of the
> wrong size would be stretched or cropped on screen, and the Pi only knows how
> to read those four file formats.

> **Taking a photo on a phone?** Phone cameras save HEIC images at odd sizes.
> Export or resize to a 1920×1080 PNG or JPEG first — most photo apps can do
> this under "Export" or "Resize".

---

## Each time you want to change the splash

1. **Open the link.** Tap your bookmark, or double-click the shortcut file.
   You should see the Kiosk Manager page with a list of the current slides.

2. **Upload your image.** In the **Splash Images** column, choose your file and
   upload it. It appears in the list once it passes the size and format checks.

3. **Remove any slide you no longer want.** Each slide has a delete button. The
   display cycles through *every* image in the list, so an old slide keeps
   showing until you delete it.

4. **Put them in the order you want.** Drag the slides, or use the ↑↓ buttons.
   The display advances one slide each time the splash comes back on screen.

5. **Press "Restart Service."** This is the step people forget. Your changes
   don't reach the screen until the display restarts, which takes a few
   seconds.

That's it. Look up at the display to confirm.

---

## What you should see when it works

Within a few seconds of pressing **Restart Service**, the worship display shows
your image. If several slides are loaded, it moves to the next one each time
the splash returns (for example, after the stream stops).

The splash only shows when the stream is **not** live. If the service is
currently streaming, the display keeps showing the stream — your new splash
appears the next time the stream stops.

---

## Common errors and what they mean

| What you see | What it means | What to do |
|---|---|---|
| "Image must be 1920×1080 px" | Your image is the wrong size | Resize it to exactly 1920×1080 and upload again |
| "Only PNG, JPEG, GIF, or WebP files are accepted" | Wrong file format (often HEIC from a phone) | Export it as a PNG or JPEG |
| "File too large" | Over the 10 MB limit | Save at a lower quality, or use PNG → JPEG |
| "Invalid image file" | The file is damaged or wasn't fully copied | Re-export the image and try again |
| The page won't load at all | You're not on the church network, or the link expired | Connect to the church Wi-Fi; if it still fails, ask the AV admin for a fresh link |
| Nothing changed on screen | You didn't press **Restart Service** | Go back and press it |

In every one of these cases, **the display keeps showing whatever it was
showing**. A failed upload can't break the screen.

---

## Security notes (please read)

Your link contains an **access token** — anyone who has it can change what the
worship display shows.

- **Don't post the link** in a group chat, on social media, or in a shared
  document.
- **Don't forward it** to someone else. Ask the AV admin to issue their own.
- If you think the link has leaked — you sent it to the wrong person, or lost
  the device it was saved on — **tell the AV admin right away.** They can rotate
  the token in seconds, which instantly invalidates every old link, including
  the leaked one.

The manager can only do three things: change the splash images, restart the
display, and reboot the Pi. It can't read files on the Pi or reach anything
else on the church network.

---

## When in doubt

Contact the church AV admin. Nothing you do in the manager is permanent — a
wrong slide is fixed by uploading a different one and pressing **Restart
Service** again.
