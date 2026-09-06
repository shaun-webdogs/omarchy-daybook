#!/usr/bin/env python3
"""Install Daybook as a user-owned Omarchy plugin, preserving previous versions."""
import argparse
import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

PLUGIN_ID = "shahin.daybook"
RUNTIME_FILES = ["manifest.json", "Widget.qml", "Service.qml", "DaybookContent.qml", "ActionButton.qml", "daybook.py", "README.md", "LICENSE"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--section", choices=["left", "center", "right"], default="right", help="Top-bar placement (default: right)")
    args = parser.parse_args()
    source = Path(__file__).resolve().parent
    subprocess.run(["omarchy", "plugin", "validate", str(source)], check=True)
    for name in RUNTIME_FILES:
        if not (source / name).is_file():
            parser.error("Missing plugin file: " + name)
    config = Path.home() / ".config/omarchy"
    target = config / "plugins" / PLUGIN_ID
    if target.is_symlink():
        parser.error("The install destination is a symlink; choose a normal plugin directory.")
    if target.exists():
        manifest = json.loads((target / "manifest.json").read_text())
        if manifest.get("id") != PLUGIN_ID:
            parser.error("The install destination contains another plugin.")
    shell_config = config / "shell.json"
    subprocess.run(["omarchy-shell", "shell", "ping"], check=True, capture_output=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    backups = config / "plugin-backups" / PLUGIN_ID / stamp
    backups.mkdir(parents=True)
    if shell_config.exists():
        shutil.copy2(shell_config, backups / "shell.json")
    target.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".daybook-stage-", dir=target.parent))
    for name in RUNTIME_FILES:
        shutil.copy2(source / name, stage / name)
    subprocess.run(["omarchy", "plugin", "validate", str(stage)], check=True)
    if target.exists():
        target.rename(backups / "plugin")
    stage.rename(target)
    subprocess.run(["omarchy-shell", "shell", "rescanPlugins"], check=True)
    # Discovery is asynchronous. Poll the read-only catalog before enabling.
    import time
    for attempt in range(60):
        response = subprocess.run(["omarchy", "plugin", "list", "--json"], capture_output=True, text=True)
        if response.returncode == 0 and any(p.get("id") == PLUGIN_ID for p in json.loads(response.stdout)):
            break
        time.sleep(0.1)
    else:
        raise RuntimeError("Plugin files installed, but discovery did not finish. Run: omarchy plugin enable shahin.daybook --section " + args.section)
    subprocess.run(["omarchy", "plugin", "enable", PLUGIN_ID, "--section", args.section], check=True)
    print(f"Installed Daybook in the {args.section} bar section. Config backup: {backups}")
    print("Task history stays in " + os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share")) + "/omarchy-daybook/daybook.sqlite3")


if __name__ == "__main__":
    main()
