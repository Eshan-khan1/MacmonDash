# dmgbuild settings for MacmonDash (loaded by Scripts/make-release.sh).
# Paths are absolute; make-release injects them via defines.

import os

# make-release.sh exports MACMONDASH_ROOT; fall back to cwd/parent of Scripts
_root = os.environ.get("MACMONDASH_ROOT")
if not _root:
    _root = os.path.abspath(os.path.join(os.getcwd()))
    if os.path.basename(_root) == "Scripts":
        _root = os.path.dirname(_root)
_app = os.path.join(_root, "dist", "MacmonDash.app")
_bg = os.path.join(_root, "Resources", "dmg-background.png")
_icns = os.path.join(_root, "Resources", "AppIcon.icns")

volume_name = "MacmonDash"
format = "UDZO"

files = [_app]
symlinks = {"Applications": "/Applications"}

badge_icon = _icns

icon_locations = {
    "MacmonDash.app": (140, 175),
    "Applications": (400, 175),
}

background = _bg

window_rect = ((200, 120), (540, 380))
icon_size = 128
text_size = 12

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

include_icon_view_settings = True
default_view = "icon-view"
arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100
scroll_position = (0, 0)
label_pos = "bottom"
