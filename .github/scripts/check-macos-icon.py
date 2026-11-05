"""Reject macOS packages that silently ship the old, uncompiled app icon."""

import plistlib
import struct
import sys
from pathlib import Path


def check_icon(app: Path) -> None:
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    xcode_version = str(info.get("DTXcode", "0"))
    if not xcode_version.isdigit() or int(xcode_version) < 2600:
        raise SystemExit("Icon Composer requires a build made with Xcode 26 or newer.")

    resources = app / "Contents/Resources"
    if (resources / "AppIcon.icon").exists():
        raise SystemExit("AppIcon.icon was copied as a raw resource instead of compiled.")
    if not (resources / "Assets.car").is_file():
        raise SystemExit("The compiled asset catalog is missing.")

    icon = (resources / "AppIcon.icns").read_bytes()
    if len(icon) < 8 or icon[:4] != b"icns" or struct.unpack(">I", icon[4:8])[0] != len(icon):
        raise SystemExit("The generated compatibility icon is not a valid ICNS file.")
    print(f"Compiled Icon Composer asset and compatibility icon verified (Xcode {xcode_version}).")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: check-macos-icon.py <application.app>")
    check_icon(Path(sys.argv[1]))
