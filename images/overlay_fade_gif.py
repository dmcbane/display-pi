#!/usr/bin/env python3
"""
overlay_fade_gif.py

Composite a fading overlay onto a base image across a looping GIF,
with selectable easing curves and loop styles.

Usage:
    python overlay_fade_gif.py base.png overlay.png -o output.gif

Run with -h for full option list.
"""

import argparse
import math
import sys
from pathlib import Path

from PIL import Image


# ---------------------------------------------------------------------------
# Easing functions: all map t in [0,1] -> eased value in [0,1]
# ---------------------------------------------------------------------------

def ease_linear(t):
    return t

def ease_in_out_quad(t):
    return 2 * t * t if t < 0.5 else 1 - ((-2 * t + 2) ** 2) / 2

def ease_in_out_cubic(t):
    return 4 * t ** 3 if t < 0.5 else 1 - ((-2 * t + 2) ** 3) / 2

def ease_in_out_quart(t):
    return 8 * t ** 4 if t < 0.5 else 1 - ((-2 * t + 2) ** 4) / 2

def ease_in_out_sine(t):
    return -(math.cos(math.pi * t) - 1) / 2

def ease_in_out_expo(t):
    if t == 0:
        return 0
    if t == 1:
        return 1
    if t < 0.5:
        return (2 ** (20 * t - 10)) / 2
    return (2 - 2 ** (-20 * t + 10)) / 2

EASINGS = {
    "linear": ease_linear,
    "quad": ease_in_out_quad,
    "cubic": ease_in_out_cubic,
    "quart": ease_in_out_quart,
    "sine": ease_in_out_sine,
    "expo": ease_in_out_expo,
}


# ---------------------------------------------------------------------------
# Loop position generators: map i/n_frames -> raw progress in [0,1]
# before easing is applied. This is where "pulse vs continuous" and
# "hold at peak/trough" get built in.
# ---------------------------------------------------------------------------

def triangle_position(t, hold_frac):
    """
    0 -> 1 -> 0 across the loop, with an optional flat hold
    at the peak (t=0.5) and trough (t=0/1).

    hold_frac: fraction of the FULL loop spent flat at the peak,
    split evenly, e.g. hold_frac=0.2 means 10% flat before peak-hold
    ends and 10% flat after. Same total flat time reserved at the
    trough (split across the wrap-around start/end).
    """
    if hold_frac <= 0:
        return 1 - abs(2 * t - 1)

    # Reserve hold_frac around the peak and hold_frac around the trough,
    # remaining time split across the four ramps.
    half_hold = hold_frac / 2
    ramp_total = 1 - 2 * hold_frac  # total time spent actually ramping
    ramp = ramp_total / 4           # each of the 4 ramps gets equal share

    # Segment boundaries over one full loop [0,1]:
    # [0, half_hold]                -> trough hold (start half)
    # [half_hold, half_hold+ramp]   -> ramp up
    # [..., ...+2*half_hold+? ]     -> peak hold, etc.
    b0 = half_hold
    b1 = b0 + ramp
    b2 = b1 + 2 * half_hold
    b3 = b2 + ramp
    # b4 = b3 + half_hold == 1.0

    if t < b0:
        return 0.0
    elif t < b1:
        return (t - b0) / ramp
    elif t < b2:
        return 1.0
    elif t < b3:
        return 1 - (t - b2) / ramp
    else:
        return 0.0


def sine_position(t):
    """Continuous 0->1->0 breathing position, no hard hold segments."""
    return 0.5 * (1 - math.cos(2 * math.pi * t))


# ---------------------------------------------------------------------------
# Core
# ---------------------------------------------------------------------------

def build_frames(base_path, overlay_path, n_frames, loop_style,
                  easing_name, hold_frac, alpha_min, alpha_max, fit):
    base = Image.open(base_path).convert("RGBA")
    overlay = Image.open(overlay_path).convert("RGBA")

    if overlay.size != base.size:
        if fit == "resize":
            overlay = overlay.resize(base.size)
        elif fit == "crop":
            ox, oy = overlay.size
            bx, by = base.size
            if ox < bx or oy < by:
                raise ValueError(
                    f"overlay {overlay.size} smaller than base {base.size}; "
                    f"cannot crop, use --fit resize"
                )
            left = (ox - bx) // 2
            top = (oy - by) // 2
            overlay = overlay.crop((left, top, left + bx, top + by))
        elif fit == "pad":
            canvas = Image.new("RGBA", base.size, (0, 0, 0, 0))
            ox, oy = overlay.size
            bx, by = base.size
            paste_x = (bx - ox) // 2
            paste_y = (by - oy) // 2
            canvas.paste(overlay, (paste_x, paste_y), overlay)
            overlay = canvas
        else:
            raise ValueError(f"unknown --fit mode: {fit}")

    ease_fn = EASINGS[easing_name]
    frames = []

    for i in range(n_frames):
        t = i / n_frames

        if loop_style == "pulse":
            pos = triangle_position(t, hold_frac)
        elif loop_style == "sine":
            pos = sine_position(t)
        else:
            raise ValueError(f"unknown --loop-style: {loop_style}")

        eased = ease_fn(pos)
        alpha_scale = alpha_min + (alpha_max - alpha_min) * eased

        ov = overlay.copy()
        r, g, b, a = ov.split()
        a = a.point(lambda p, s=alpha_scale: int(p * s))
        ov.putalpha(a)

        frame = Image.alpha_composite(base, ov).convert("RGB")
        frames.append(frame)

    return frames


def main():
    p = argparse.ArgumentParser(
        description="Composite a fading overlay onto a base image into a looping GIF."
    )
    p.add_argument("base", help="path to base image")
    p.add_argument("overlay", help="path to overlay image (RGBA alpha preserved if present)")
    p.add_argument("-o", "--output", default="output.gif", help="output GIF path")

    p.add_argument("--frames", type=int, default=40, help="frames per loop (default: 40)")
    p.add_argument("--fps", type=float, default=20, help="playback fps (default: 20)")

    p.add_argument("--loop-style", choices=["pulse", "sine"], default="pulse",
                    help="'pulse' = fade in then out once per loop with optional hold; "
                         "'sine' = continuous smooth breathing (default: pulse)")
    p.add_argument("--easing", choices=list(EASINGS.keys()), default="cubic",
                    help="easing curve applied to the fade motion (default: cubic)")
    p.add_argument("--hold", type=float, default=0.0,
                    help="fraction (0-0.9) of loop spent flat at peak/trough, "
                         "'pulse' style only (default: 0.0, no hold)")

    p.add_argument("--alpha-min", type=float, default=0.0,
                    help="minimum overlay opacity, 0-1 (default: 0.0)")
    p.add_argument("--alpha-max", type=float, default=0.85,
                    help="maximum overlay opacity, 0-1 (default: 0.85)")

    p.add_argument("--fit", choices=["resize", "crop", "pad"], default="resize",
                    help="how to reconcile mismatched overlay/base dimensions "
                         "(default: resize)")

    p.add_argument("--optimize", action="store_true",
                    help="enable GIF palette optimization (test fades without this first; "
                         "can introduce banding near low-alpha frames)")
    p.add_argument("--gif-loops", type=int, default=0,
                    help="number of times the GIF repeats, 0 = infinite (default: 0)")

    args = p.parse_args()

    if not 0 <= args.hold < 1:
        p.error("--hold must be in [0, 1)")
    if not 0 <= args.alpha_min <= 1 or not 0 <= args.alpha_max <= 1:
        p.error("--alpha-min/--alpha-max must be in [0, 1]")
    if args.alpha_min > args.alpha_max:
        p.error("--alpha-min cannot exceed --alpha-max")
    if args.hold > 0 and args.loop_style != "pulse":
        print("note: --hold has no effect with --loop-style sine", file=sys.stderr)

    for path in (args.base, args.overlay):
        if not Path(path).is_file():
            p.error(f"file not found: {path}")

    frames = build_frames(
        base_path=args.base,
        overlay_path=args.overlay,
        n_frames=args.frames,
        loop_style=args.loop_style,
        easing_name=args.easing,
        hold_frac=args.hold,
        alpha_min=args.alpha_min,
        alpha_max=args.alpha_max,
        fit=args.fit,
    )

    duration_ms = int(1000 / args.fps)
    frames[0].save(
        args.output,
        save_all=True,
        append_images=frames[1:],
        duration=duration_ms,
        loop=args.gif_loops,
        optimize=args.optimize,
    )
    print(f"wrote {args.output} ({len(frames)} frames, {duration_ms}ms/frame)")


if __name__ == "__main__":
    main()
