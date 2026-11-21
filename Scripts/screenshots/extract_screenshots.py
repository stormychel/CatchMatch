#!/usr/bin/env python3
#
#  extract_screenshots.py
#  CatchMatch
#
#  Created by Michel Storms on 19/09/2026.
#
"""Pull the ScreenshotTests attachments out of an xcresult into
Scripts/screenshots/output/<timestamp>/raw/<name>.png. #105"""

import json
import re
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent
RESULT_BUNDLE = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/tmp/catchmatch-screenshots.xcresult")
OUTPUT_DIR = ROOT / "output" / datetime.now().strftime("%Y-%m-%d_%H%M%S") / "raw"
ATTACHMENT_DIR = Path("/tmp/catchmatch-attachments")

# "01_Queue_0_<UUID>.png" -> "01_Queue"
NAME_PATTERN = re.compile(r"^(\d{2}_[A-Za-z_]+?)_\d+_")


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    if ATTACHMENT_DIR.exists():
        shutil.rmtree(ATTACHMENT_DIR)
    subprocess.run(
        ["xcrun", "xcresulttool", "export", "attachments",
         "--path", str(RESULT_BUNDLE), "--output-path", str(ATTACHMENT_DIR)],
        check=True,
    )
    manifest = json.loads((ATTACHMENT_DIR / "manifest.json").read_text())
    count = 0
    for test in manifest:
        for att in test.get("attachments", []):
            match = NAME_PATTERN.match(att["suggestedHumanReadableName"])
            if not match:
                continue
            dst = OUTPUT_DIR / f"{match.group(1)}.png"
            shutil.copy2(ATTACHMENT_DIR / att["exportedFileName"], dst)
            print(f"  {dst.name}")
            count += 1
    if count == 0:
        sys.exit("No screenshot attachments found — did ScreenshotTests run?")
    print(f"Extracted {count} screenshots to {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
