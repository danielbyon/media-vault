#!/usr/bin/env python3
"""Render per-case observations without inferring a callback from menu visibility."""

from __future__ import annotations

import json
import sys
from pathlib import Path


def fields(event: dict[str, object]) -> dict[str, str]:
    value = event.get("fields")
    return value if isinstance(value, dict) else {}


def summarize(evidence: dict[str, object], device: str) -> str:
    """Keep observed event delivery separate from native API availability."""
    device = {
        "iphone": "iPhone 17 (iOS 27)",
        "ipad": "iPad Pro 11-inch (M5) (iPadOS 27)",
    }.get(device, device)
    events = evidence["events"]
    resources_by_press: dict[str, set[str]] = {}
    legacy_resources_by_case: dict[str, set[str]] = {}
    current_case = ""
    for request in evidence.get("requests", []):
        path = request.get("path", "")
        if path.startswith("/case/"):
            current_case = path.removeprefix("/case/")
        elif path.startswith("/media/") and current_case:
            press_id = request.get("pressID")
            if press_id:
                resources_by_press.setdefault(press_id, set()).add(path)
            else:
                legacy_resources_by_case.setdefault(current_case, set()).add(path)
    lines = [
        f"# {device} inline-media observations",
        "",
        "SwiftUI `.webViewContextMenu` is unavailable on iOS 27 in the installed SDK. "
        "Menu accessibility does not imply an app callback or a selected URL.",
        "",
        "| Mode | Case | Fixture media GETs | Native menu seen | Native callback | Menu labels | JS contextmenu | Diagnostic touch/pointer | Selected media | Link destination | Native frame | Frame request | Rejections |",
        "| --- | --- | --- | --- | --- | --- | ---: | ---: | --- | --- | --- | --- | --- |",
    ]
    for event in events:
        if event.get("kind") != "ui-press":
            continue
        press = fields(event)
        case_id = press.get("case", "unknown")
        mode = press.get("mode", "unknown")
        press_id = press.get("pressID")
        matching = [
            item for item in events
            if fields(item).get("case") == case_id
            and fields(item).get("mode") == mode
            and (not press_id or fields(item).get("pressID") == press_id)
        ]
        observations = [fields(item) for item in matching if item.get("kind") == "bridge-observation"]
        rejected = sorted({fields(item).get("reason", "unknown") for item in matching if item.get("kind") == "bridge-rejected"})
        context = [item for item in observations if item.get("event") == "contextmenu"]
        diagnostic = [item for item in observations if item.get("event") in ("pointerdown", "touchstart")]
        source = context[-1] if context else (diagnostic[-1] if diagnostic else {})
        frame = "absent"
        if source:
            frame = f"{source.get('nativeOrigin', 'absent')} (main={source.get('nativeMainFrame', '?')})"
        press_resources = resources_by_press.get(press_id, set()) if press_id else set()
        legacy_resources = legacy_resources_by_case.get(case_id, set())
        fixture_media = ", ".join(sorted(press_resources or legacy_resources))
        if not fixture_media and case_id in ("blob", "data"):
            fixture_media = f"in-page {case_id} JPEG"
        lines.append("| " + " | ".join([
            mode,
            case_id,
            fixture_media or "none",
            press.get("menuAccessibilityDetected", "unreported"),
            "unavailable on iOS 27",
            press.get("menuLabels", "").replace("|", "\\|"),
            str(len(context)),
            str(len(diagnostic)),
            source.get("selectedMedia", "absent"),
            source.get("linkDestination", "absent"),
            frame,
            source.get("nativeRequest", "absent"),
            ", ".join(rejected) or "none",
        ]) + " |")
    lines.append("")
    lines.append("The menu column is an XCUITest accessibility observation after `press(forDuration: 1.1)`. "
                 "An empty callback/URL column is recorded as unavailable or undelivered, not as a URL-returning callback with no URL.")
    return "\n".join(lines) + "\n"


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("Usage: summarize_evidence.py evidence.json device-name")
    evidence = json.loads(Path(sys.argv[1]).read_text())
    print(summarize(evidence, sys.argv[2]), end="")


if __name__ == "__main__":
    main()
