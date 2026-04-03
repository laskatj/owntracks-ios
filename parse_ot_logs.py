#!/usr/bin/env python3
"""
parse_ot_logs.py - Filter OwnTracks iOS logs for wake/SLC/geofence/kill events.

Usage:
    python3 parse_ot_logs.py [log_dir] [--output FILE] [--verbose]

Options:
    log_dir       Directory containing log files (default: script directory)
    --output FILE Write output to FILE (default: filtered_ot_<timestamp>.log)
    --verbose     Also include PUBLISH events (sendData, activityTimer) —
                  adds ~30s cadence location publishes; useful to see coords

Defaults to the directory containing this script.
Output defaults to filtered_ot_<timestamp>.log in the same directory.
"""

import re
import sys
import glob
import os
from datetime import datetime, timezone

# ---------------------------------------------------------------------------
# Filter categories — order matters: first match wins for label assignment.
# Each entry: (label, [patterns...], default_on)
# Patterns are case-insensitive substring matches.
# ---------------------------------------------------------------------------
FILTER_CATEGORIES = [
    ("LIFECYCLE",  [
        "applicationDidFinishLaunching",
        "applicationDidBecomeActive",
        "applicationDidEnterBackground",
        "applicationWillTerminate",
        "applicationWillResignActive",
        "bgTaskExpirationHandler",
    ], True),
    ("KILL/BG",    [
        "disconnectInBackground",
        "endBackGroundTask",
        "stopInBackground",
        "startBackgroundTimer",
        "holdTimer",
        "bgTimer",
        "disconnectTimer",
    ], True),
    ("WAKE/SLC",   [
        "backgroundWakeup",
        "BACKGROUND WAKEUP",
        "RELAUNCH after TERMINATION",
        "FOREGROUND RETURN",
        "Move/passive",
        "Move/active",
        "UIApplicationLaunchOptionsLocationKey",
        "wakeup",
    ], True),
    ("GEOFENCE",   [
        "didEnterRegion",
        "didExitRegion",
        "startMonitoringForRegion",
        "stopMonitoringForRegion",
        "monitoredRegions",
        "+follow",
        "followRegion",
        "RegionEvent",
    ], True),
    ("GPS/MODE",   [
        "startUpdatingLocation",
        "stopUpdatingLocation",
        "SLC started",
        "Visits started",
        "SUPPRESSED",
    ], True),
    # PUBLISH: verbose — only included with --verbose flag
    ("PUBLISH",    [
        "sendData(",
        "stored location",
        "Location#1 delivered",
        "activityTimer fired",
    ], False),
]

# Compiled at runtime once verbose flag is known (see build_compiled)
_compiled = []


def build_compiled(verbose=False):
    global _compiled
    _compiled = []
    for label, patterns, default_on in FILTER_CATEGORIES:
        if default_on or verbose:
            for p in patterns:
                _compiled.append((label, p.lower()))

TIMESTAMP_RE = re.compile(r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z)')


def parse_timestamp(line):
    m = TIMESTAMP_RE.match(line)
    if not m:
        return None
    ts_str = m.group(1)
    # Normalize to microseconds for fromisoformat
    ts_str = ts_str.rstrip('Z')
    # Pad or trim fractional seconds to 6 digits
    if '.' in ts_str:
        base, frac = ts_str.split('.')
        ts_str = f"{base}.{frac[:6].ljust(6, '0')}"
    else:
        ts_str = f"{ts_str}.000000"
    return datetime.fromisoformat(ts_str).replace(tzinfo=timezone.utc)


def categorize(line):
    lower = line.lower()
    for label, pattern in _compiled:
        if pattern in lower:
            return label
    return None


def pdt_str(dt):
    """Convert UTC datetime to PDT (UTC-7) human-readable string."""
    pdt_offset = -7 * 3600
    pdt_ts = dt.timestamp() + pdt_offset
    pdt_dt = datetime.utcfromtimestamp(pdt_ts)
    return pdt_dt.strftime('%H:%M:%S PDT')


def main():
    args = sys.argv[1:]
    output_file = None
    verbose = False

    # Parse flags
    if '--verbose' in args:
        verbose = True
        args.remove('--verbose')

    if '--output' in args:
        idx = args.index('--output')
        output_file = args[idx + 1]
        args = args[:idx] + args[idx + 2:]

    build_compiled(verbose)

    log_dir = args[0] if args else os.path.dirname(os.path.abspath(__file__))
    log_dir = os.path.abspath(log_dir)

    if output_file is None:
        ts = datetime.now().strftime('%Y%m%d_%H%M%S')
        output_file = os.path.join(log_dir, f'filtered_ot_{ts}.log')

    pattern = os.path.join(log_dir, 'org.laskatj.owntracksfork*.log')
    log_files = sorted(glob.glob(pattern))

    if not log_files:
        print(f"No log files matching 'org.laskatj.owntracksfork*.log' found in {log_dir}")
        sys.exit(1)

    print(f"Found {len(log_files)} log file(s):")
    for f in log_files:
        print(f"  {os.path.basename(f)}")

    entries = []  # (datetime, label, filename, line)

    for log_path in log_files:
        filename = os.path.basename(log_path)
        with open(log_path, 'r', encoding='utf-8', errors='replace') as fh:
            for raw_line in fh:
                line = raw_line.rstrip('\n')
                label = categorize(line)
                if label is None:
                    continue
                ts = parse_timestamp(line)
                if ts is None:
                    continue
                entries.append((ts, label, filename, line))

    entries.sort(key=lambda e: e[0])

    label_counts = {}
    for _, label, _, _ in entries:
        label_counts[label] = label_counts.get(label, 0) + 1

    with open(output_file, 'w', encoding='utf-8') as out:
        out.write(f"# OwnTracks filtered log — generated {datetime.now().isoformat()}\n")
        out.write(f"# Source dir:  {log_dir}\n")
        out.write(f"# Log files:   {len(log_files)}\n")
        out.write(f"# Matched lines: {len(entries)}{' (--verbose)' if verbose else ''}\n")
        out.write(f"# Categories:  {label_counts}\n")
        out.write("#\n")
        out.write(f"# {'TIMESTAMP (UTC)':<28} {'PDT':<13} {'CATEGORY':<12} {'FILE':<45} MESSAGE\n")
        out.write(f"# {'-'*28} {'-'*13} {'-'*12} {'-'*45} {'-'*60}\n")

        prev_file = None
        for ts, label, filename, line in entries:
            if filename != prev_file:
                out.write(f"\n# --- {filename} ---\n")
                prev_file = filename

            # Strip the raw timestamp prefix from line for cleaner output
            msg = TIMESTAMP_RE.sub('', line).strip()
            pdt = pdt_str(ts)
            ts_str = ts.strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'
            out.write(f"{ts_str}  {pdt:<13} {label:<12} {filename:<45} {msg}\n")

    print(f"\nWrote {len(entries)} filtered lines → {output_file}")
    print(f"Category breakdown: {label_counts}")


if __name__ == '__main__':
    main()
