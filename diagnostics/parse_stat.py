#!/usr/bin/env python3
# parse_stat.py — parse nginx-rtmp /stat XML for judder.sh.
#
# Three modes:
#   probe       — verbose per-app/per-stream summary for the probe block.
#   stream-key  — terse one-line publisher lookup for day-of-event triage.
#   status      — "STATUS|label|detail" rows for render-status.sh, one per
#                 publishing stream (WARN on key mismatch, OK otherwise).
#
# Reads XML from stdin. --expected-key tags publishers as matching/mismatched
# the key the player is hardcoded to subscribe to.
#
# Defensive defaults: defusedxml when available, namespace-stripped, and
# .//stream so nesting variations (rtmp/server/application/live/stream vs
# rtmp/application/live/stream) both parse. The /stat endpoint nginx serves
# is loopback-only, but treating its input as untrusted costs nothing.

import argparse
import sys


def _import_et():
    try:
        from defusedxml import ElementTree as ET  # type: ignore
        return ET, True
    except ImportError:
        from xml.etree import ElementTree as ET
        return ET, False


def _strip_ns(root):
    for el in root.iter():
        if isinstance(el.tag, str) and el.tag.startswith("{"):
            el.tag = el.tag.split("}", 1)[1]


def _parse(xml_bytes):
    ET, _ = _import_et()
    try:
        root = ET.fromstring(xml_bytes)
    except ET.ParseError as exc:
        print(f"ERROR: stat XML parse failed: {exc}", file=sys.stderr)
        sys.exit(2)
    _strip_ns(root)
    return root


def _streams_under(app):
    return app.findall(".//stream")


def _nclients(app):
    live = app.find(".//live")
    if live is None:
        return None
    text = (live.findtext("nclients") or "").strip()
    return text or None


def _publisher(stream):
    for c in stream.findall("client"):
        if c.find("publishing") is not None:
            return c
    return None


def _non_publishers(stream):
    return [c for c in stream.findall("client") if c.find("publishing") is None]


def cmd_probe(root, expected_key):
    apps = root.findall(".//application")
    if not apps:
        print("no <application> blocks (rtmp_stat returned empty)")
        return
    any_pub = False
    for app in apps:
        app_name = (app.findtext("name") or "?").strip()
        streams = _streams_under(app)
        nclients = _nclients(app)
        if not streams:
            if nclients is not None:
                print(f"app={app_name}: no publisher (nclients={nclients})")
            else:
                print(f"app={app_name}: no active streams")
            continue
        for s in streams:
            name = (s.findtext("name") or "?").strip()
            bw_in = (s.findtext("bw_in") or "0").strip()
            pub = _publisher(s)
            subs = len(_non_publishers(s))
            if pub is not None:
                any_pub = True
                addr = (pub.findtext("address") or "?").strip()
                flash = (pub.findtext("flashver") or "").strip()
                tag = (
                    "  <-- matches player"
                    if name == expected_key
                    else f"  *** MISMATCH: player expects key={expected_key}"
                )
                print(
                    f"app={app_name} key={name} pub={addr} "
                    f"flashver={flash!r} bw_in={bw_in} subs={subs}{tag}"
                )
            else:
                print(
                    f"app={app_name} key={name} (no publisher) "
                    f"subs={subs} bw_in={bw_in}"
                )
    if not any_pub:
        print(f"(no active publishers; player expects key={expected_key})")


def cmd_stream_key(root, expected_key):
    any_pub = False
    for s in root.findall(".//stream"):
        name = (s.findtext("name") or "?").strip()
        bw_in = (s.findtext("bw_in") or "0").strip()
        pub = _publisher(s)
        if pub is None:
            continue
        any_pub = True
        addr = (pub.findtext("address") or "?").strip()
        flash = (pub.findtext("flashver") or "").strip()
        tag = (
            "  <-- matches player"
            if name == expected_key
            else f"  *** MISMATCH: player expects key={expected_key}"
        )
        print(f"key={name} pub={addr} flashver={flash!r} bw_in={bw_in}{tag}")
    if not any_pub:
        print(f"(no active publishers; player expects key={expected_key})")


def _fmt_bw(bw_in):
    # nginx-rtmp bw_in is bits/second; render as Mb/s for the status screen.
    try:
        bits = int(bw_in)
    except (TypeError, ValueError):
        return ""
    return f" {bits / 1_000_000:.1f} Mb/s"


def cmd_status(root, expected_key):
    # Rows for render-status.sh: "STATUS|label|detail", one per publishing
    # stream. Keys and app names are publisher-controlled — keep '|' out of
    # them so the row stays parseable by the bash IFS='|' read.
    any_pub = False
    for app in root.findall(".//application"):
        app_name = (app.findtext("name") or "?").strip().replace("|", "?")
        for s in _streams_under(app):
            pub = _publisher(s)
            if pub is None:
                continue
            any_pub = True
            name = (s.findtext("name") or "?").strip().replace("|", "?")
            addr = (pub.findtext("address") or "?").strip().replace("|", "?")
            bw = _fmt_bw((s.findtext("bw_in") or "").strip())
            if name == expected_key:
                print(f"OK|Publisher|{app_name}/{name} from {addr}{bw}")
            else:
                print(
                    f"WARN|Publisher|{app_name}/{name} from {addr}{bw}"
                    f" (player expects {expected_key})"
                )
    if not any_pub:
        print("OK|Publishers|none")


def main(argv):
    p = argparse.ArgumentParser(description="Parse nginx-rtmp /stat XML for judder.sh.")
    p.add_argument("mode", choices=("probe", "stream-key", "status"))
    p.add_argument(
        "--expected-key",
        required=True,
        help="The stream key the kiosk player is subscribed to.",
    )
    args = p.parse_args(argv)

    xml_bytes = sys.stdin.buffer.read()
    if not xml_bytes.strip():
        print("ERROR: stat XML empty on stdin", file=sys.stderr)
        return 2
    root = _parse(xml_bytes)
    if args.mode == "probe":
        cmd_probe(root, args.expected_key)
    elif args.mode == "status":
        cmd_status(root, args.expected_key)
    else:
        cmd_stream_key(root, args.expected_key)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
