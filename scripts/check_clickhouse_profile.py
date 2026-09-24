#!/usr/bin/env python3
"""Fail when the ClickHouse small profile drifts between Helm and compose.

The profile's source of truth is chart/files/clickhouse/ (the chart can only
read files inside chart/). docker-compose cannot mount those files without
breaking install.sh, which downloads docker/clickhouse/{config,users}.xml from
purlogs.com, so the compose files carry the same settings inline.

Every leaf setting in a chart profile file (an element with no child
elements) must appear in its compose twin exactly once, at the same path,
with the same text and attributes. The compose file may add settings of its
own. Stdlib only: runs on any CI runner and on macOS without extra packages.

The purl-web site serves its own copies for install.sh
(public/config/clickhouse-{config,users}.xml). When a purl-web checkout sits
next to this repo (../purl-web), those copies are checked too, but only as
WARNINGS: CI has no purl-web checkout, and that repo is released separately.

Usage: scripts/check_clickhouse_profile.py   (from the repo root)
Exit 0 = in sync (warnings allowed), 1 = drift in this repo, 2 = unreadable file.
"""
import os
import sys
import xml.etree.ElementTree as ET

PAIRS = [
    ("chart/files/clickhouse/purl-small.xml", "docker/clickhouse/config.xml"),
    ("chart/files/clickhouse/purl-small-profile.xml", "docker/clickhouse/users.xml"),
]

# Website copies install.sh downloads. Checked only if the checkout exists.
WEB_PAIRS = [
    ("chart/files/clickhouse/purl-small.xml", "../purl-web/public/config/clickhouse-config.xml"),
    ("chart/files/clickhouse/purl-small-profile.xml", "../purl-web/public/config/clickhouse-users.xml"),
]


def leaves(elem, path=()):
    """Yield (path, text, attrib) for every element without child elements."""
    children = list(elem)
    if not children:
        yield path, (elem.text or "").strip(), dict(elem.attrib)
        return
    for child in children:
        yield from leaves(child, path + (child.tag,))


def find_all(root, path):
    nodes = [root]
    for tag in path:
        nodes = [child for node in nodes for child in node if child.tag == tag]
    return nodes


def compare(canonical, twin):
    """Return a list of drift messages for one canonical/twin pair."""
    src = ET.parse(canonical).getroot()
    dst = ET.parse(twin).getroot()
    problems = []
    count = 0
    for path, text, attrib in leaves(src):
        count += 1
        where = "/".join(path)
        found = find_all(dst, path)
        if len(found) != 1:
            problems.append(f"{twin}: <{where}> appears {len(found)} times, expected 1 "
                            f"(canonical: {canonical})")
            continue
        node = found[0]
        if list(node):
            problems.append(f"{twin}: <{where}> has child elements, {canonical} has a value")
            continue
        got = (node.text or "").strip()
        if got != text or dict(node.attrib) != attrib:
            problems.append(f"{twin}: <{where}> is {got!r} {dict(node.attrib)}, "
                            f"{canonical} says {text!r} {attrib}")
    if count == 0:
        problems.append(f"{canonical}: no settings found")
    return problems


def main():
    problems = []
    for canonical, twin in PAIRS:
        try:
            problems += compare(canonical, twin)
        except (OSError, ET.ParseError) as err:
            print(f"cannot read profile file: {err}", file=sys.stderr)
            return 2
    for line in problems:
        print(f"  DRIFT: {line}")

    web_drift = 0
    for canonical, twin in WEB_PAIRS:
        if not os.path.exists(twin):
            continue
        try:
            found = compare(canonical, twin)
        except (OSError, ET.ParseError) as err:
            found = [f"cannot read: {err}"]
        web_drift += len(found)
        for line in found[:5]:
            print(f"  WARNING (purl-web copy, not failing): {line}")
        if len(found) > 5:
            print(f"  WARNING (purl-web copy, not failing): ... and {len(found) - 5} more in {twin}")
    if web_drift:
        print(f"  WARNING: {web_drift} setting(s) differ in the purl-web copies that install.sh "
              "downloads. Re-sync ../purl-web/public/config/ from docker/clickhouse/.")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
