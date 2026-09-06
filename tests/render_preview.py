"""Render the real QML panels with fictional data for the public README."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
shell = Path(os.environ.get("OMARCHY_PATH", "/usr/share/omarchy")) / "shell"
with tempfile.TemporaryDirectory(prefix="daybook-preview-") as directory:
    stage = Path(directory)
    for name in ("Commons", "Ui"):
        (stage / name).symlink_to(shell / name, target_is_directory=True)
    (stage / "Plugin").symlink_to(root, target_is_directory=True)
    shutil.copy2(root / "tests/Preview.qml", stage / "shell.qml")
    environment = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_QUICK_BACKEND="software",
                       QT_QPA_PLATFORMTHEME="generic", QT_STYLE_OVERRIDE="Fusion",
                       XDG_RUNTIME_DIR=directory, DAYBOOK_PREVIEW_PATH=str(root / "preview.png"))
    result = subprocess.run(["quickshell", "-p", str(stage), "--no-color"], env=environment,
                            capture_output=True, text=True, timeout=15)
    output = result.stdout + result.stderr
    if result.returncode or "PREVIEW SAVED" not in output:
        print(output)
        raise SystemExit(1)
    print(root / "preview.png")
