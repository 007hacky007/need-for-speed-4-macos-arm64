# dmgbuild settings for the NFSIV Builder disk image.
# Usage: dmgbuild -s builder/dmg/settings.py -D app="dist/NFSIV Builder.app" \
#   "NFSIV Builder <version>" dist/NFSIV-Builder.dmg
import os
import subprocess
import tempfile

# dmgbuild does not define __file__; run from the repo root or pass -D assets=DIR.
here = os.path.abspath(defines.get("assets", "builder/dmg"))  # noqa: F821
app = defines["app"]  # noqa: F821 - provided by dmgbuild
app_name = os.path.basename(app.rstrip("/"))

# HiDPI background: 1x and 2x PNGs combined into one multi-representation TIFF.
_tiff = os.path.join(tempfile.mkdtemp(prefix="nfsiv-dmg-"), "background.tiff")
subprocess.check_call([
    "tiffutil", "-cathidpicheck",
    os.path.join(here, "background.png"),
    os.path.join(here, "background@2x.png"),
    "-out", _tiff,
])

format = "UDZO"
files = [app]
symlinks = {}
background = _tiff
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
# 600 background + 28 title bar; the bottom 60 px are blank so Finder's
# path bar and status bar (if enabled) never cover the notes.
window_rect = ((200, 120), (760, 628))
default_view = "icon-view"
icon_size = 86
text_size = 12
# Icon center, matching the pencil circle drawn in the background.
icon_locations = {app_name: (139, 95)}
