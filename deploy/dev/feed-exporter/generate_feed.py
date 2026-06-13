#!/usr/bin/env python3
"""fountel additive feed-export job (issue #4).

Regenerates the published MISP feed-format snapshot (``manifest.json`` +
per-event JSON + ``hashes.csv``) on a schedule, using **MISP-native feed
generation** via PyMISP — the same path as the upstream PyMISP
``examples/feed-generator/generate.py`` reference (query the REST API under a
tag/org filter, then ``MISPEvent.to_feed()``). Upstream MISP is never forked
and nothing reaches into the DB.

On top of the reference it adds the fountel requirements from #4:

* **Pinned additive filter** from ``export-filter.yaml`` (tags + org), plus a
  post-generation check that every exported event is in scope — a snapshot
  containing any out-of-scope event is rejected, not published.
* **Atomic publish**: each run writes a fresh snapshot dir and atomically
  repoints the ``public`` symlink, so nginx never serves a half-written
  snapshot.
* **Freshness sidecar** ``fountel-feed-meta.json`` (carrying ``generated_at``),
  written into the same snapshot as part of the atomic swap. No non-UUID
  top-level key is ever added to ``manifest.json``.
* **No signed output**: GPG feed signing stays disabled; no ``.asc`` artifact
  is produced.
"""

from __future__ import annotations

import json
import os
import shutil
import signal
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import yaml
from pymisp import PyMISP


# --- configuration (env, with dev-friendly defaults) -----------------------

MISP_URL = os.environ.get("MISP_URL", "https://misp-core")
# The exporter authenticates with the MISP admin/automation key. compose
# injects it from secrets/misp.secrets.env as ADMIN_KEY; MISP_KEY overrides.
MISP_KEY = os.environ.get("MISP_KEY") or os.environ.get("ADMIN_KEY", "")
MISP_VERIFY_SSL = os.environ.get("MISP_VERIFY_SSL", "false").lower() in (
    "1", "true", "yes",
)

FILTER_PATH = Path(os.environ.get("FEED_FILTER_PATH", "/app/export-filter.yaml"))
# Root of the shared publish volume. Holds snapshots/ and the `public` symlink
# nginx serves; the symlink swap is the atomic-publish primitive.
OUTPUT_DIR = Path(os.environ.get("FEED_OUTPUT_DIR", "/feed"))
EXPORT_INTERVAL = int(os.environ.get("FEED_EXPORT_INTERVAL", "300"))
SNAPSHOT_RETENTION = max(1, int(os.environ.get("FEED_SNAPSHOT_RETENTION", "5")))
RUN_ONCE = os.environ.get("RUN_ONCE", "").lower() in ("1", "true", "yes")

SNAPSHOTS = OUTPUT_DIR / "snapshots"
PUBLIC_LINK = OUTPUT_DIR / "public"

_stop = False


def log(msg: str) -> None:
    print(f"[feed-exporter] {msg}", flush=True)


def load_filter() -> dict:
    with FILTER_PATH.open() as fh:
        cfg = yaml.safe_load(fh) or {}
    tags = cfg.get("tags") or []
    org = cfg.get("org") or None
    dists = cfg.get("valid_attribute_distribution_levels") or [0, 1, 2, 3, 4, 5]
    if cfg.get("with_signatures"):
        # Hard stop: a signed feed would imply pinning a key that does not
        # exist (#4). Refuse rather than silently emit .asc artifacts.
        sys.exit("with_signatures must stay false (see export-filter.yaml).")
    return {
        "tags": list(tags),
        "org": org,
        "valid_distributions": [int(d) for d in dists],
    }


def search_filters(flt: dict) -> dict:
    """Build the REST `search_index` filter kwargs from the pinned config."""
    out: dict = {}
    if flt["tags"]:
        out["tags"] = flt["tags"]
    if flt["org"]:
        out["org"] = flt["org"]
    return out


def in_scope(event_feed: dict, flt: dict) -> tuple[bool, str]:
    """Verify a to_feed() event is within the pinned additive scope.

    Belt-and-suspenders on top of the server-side filter: confirms the
    required tag(s) and org are actually present on the exported event, so a
    snapshot can never publish an out-of-scope event.
    """
    ev = event_feed.get("Event", {})
    tag_names = {t.get("name") for t in ev.get("Tag", []) if isinstance(t, dict)}
    for required in flt["tags"]:
        if required not in tag_names:
            return False, f"missing tag {required!r}"
    if flt["org"]:
        orgc = (ev.get("Orgc") or {}).get("name")
        if orgc != flt["org"]:
            return False, f"org {orgc!r} != {flt['org']!r}"
    return True, "ok"


def generate_snapshot(misp: PyMISP, flt: dict, dest: Path) -> int:
    """Generate the feed-format files into `dest`. Returns the event count.

    Mirrors PyMISP's feed-generator: search_index for the candidate UUIDs,
    then get_event + to_feed per event, accumulating manifest + hashes.
    """
    dest.mkdir(parents=True, exist_ok=True)
    manifest: dict = {}
    hashes: list[tuple[str, str]] = []

    events = misp.search_index(minimal=True, pythonify=False, **search_filters(flt))
    log(f"search_index matched {len(events)} event(s) for the additive filter")

    for entry in events:
        uuid = entry["uuid"]
        event = misp.get_event(uuid, pythonify=True)
        feed = event.to_feed(
            valid_distributions=flt["valid_distributions"],
            with_meta=True,
            with_distribution=False,
        )
        if not feed:
            log(f"skipping {uuid}: invalid distribution")
            continue

        ok, why = in_scope(feed, flt)
        if not ok:
            # Refuse the whole snapshot — never publish out-of-scope data.
            raise RuntimeError(f"event {uuid} is out of additive scope: {why}")

        hashes += [[h, uuid] for h in feed["Event"].pop("_hashes")]
        manifest.update(feed["Event"].pop("_manifest"))
        (dest / f"{uuid}.json").write_text(json.dumps(feed, indent=2))

    # manifest.json stays a pure UUID-keyed object — no fountel top-level key.
    (dest / "manifest.json").write_text(json.dumps(manifest))
    with (dest / "hashes.csv").open("w") as fh:
        for value, uuid in hashes:
            fh.write(f"{value},{uuid}\n")

    # Freshness as a sidecar (NOT inside manifest.json) — read by the
    # aimer-web adapter alongside nginx's Last-Modified/ETag.
    meta = {
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "event_count": len(manifest),
        "filter": {"tags": flt["tags"], "org": flt["org"]},
        "generator": "fountel-feed-exporter",
        "signed": False,
    }
    (dest / "fountel-feed-meta.json").write_text(json.dumps(meta, indent=2))
    return len(manifest)


def atomic_publish(snapshot: Path) -> None:
    """Atomically repoint `public` -> snapshot via a rename of the symlink.

    The target is stored RELATIVE (`snapshots/<name>`) so it resolves under
    both the exporter's `/feed` mount and nginx's `/srv/feed` mount. Replacing
    a symlink with os.replace is atomic on the shared volume's filesystem.
    """
    rel_target = os.path.join("snapshots", snapshot.name)
    tmp_link = OUTPUT_DIR / f".public.{os.getpid()}.tmp"
    if tmp_link.is_symlink() or tmp_link.exists():
        tmp_link.unlink()
    tmp_link.symlink_to(rel_target)
    os.replace(tmp_link, PUBLIC_LINK)


def prune_snapshots(keep: Path) -> None:
    """Keep the newest SNAPSHOT_RETENTION snapshots plus the live one."""
    if not SNAPSHOTS.is_dir():
        return
    dirs = sorted(
        (d for d in SNAPSHOTS.iterdir() if d.is_dir()),
        key=lambda d: d.name,
        reverse=True,
    )
    for stale in dirs[SNAPSHOT_RETENTION:]:
        if stale.resolve() == keep.resolve():
            continue
        shutil.rmtree(stale, ignore_errors=True)


def export_once(flt: dict) -> None:
    misp = PyMISP(MISP_URL, MISP_KEY, MISP_VERIFY_SSL)
    SNAPSHOTS.mkdir(parents=True, exist_ok=True)
    # Sortable, unique snapshot name. usec suffix avoids same-second clashes.
    now = datetime.now(timezone.utc)
    name = now.strftime("%Y%m%dT%H%M%S") + f"{now.microsecond:06d}"
    snapshot = SNAPSHOTS / name

    try:
        count = generate_snapshot(misp, flt, snapshot)
    except Exception:
        shutil.rmtree(snapshot, ignore_errors=True)
        raise

    atomic_publish(snapshot)
    prune_snapshots(keep=snapshot)
    log(f"published snapshot {name} ({count} event(s)).")


def _handle_signal(signum, _frame) -> None:
    global _stop
    _stop = True
    log(f"received signal {signum}, will stop after the current cycle.")


def main() -> int:
    if not MISP_KEY:
        sys.exit("No MISP API key: set MISP_KEY or provide ADMIN_KEY via env_file.")
    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    flt = load_filter()
    log(
        f"export filter: tags={flt['tags']} org={flt['org']} "
        f"interval={EXPORT_INTERVAL}s once={RUN_ONCE}"
    )

    while not _stop:
        try:
            export_once(flt)
        except Exception as exc:  # keep the scheduler alive across MISP hiccups
            log(f"export failed: {exc}")
            if RUN_ONCE:
                return 1
        if RUN_ONCE:
            return 0
        # Sleep in short slices so SIGTERM is honored promptly.
        for _ in range(EXPORT_INTERVAL):
            if _stop:
                break
            time.sleep(1)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
