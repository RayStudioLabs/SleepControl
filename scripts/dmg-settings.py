"""Finder layout for the two-icon SleepControl installer (dmgbuild settings)."""

import os

application = defines["app"]
app_name = os.path.basename(application)
format = "UDZO"
compression_level = 9
filesystem = "HFS+"
files = [application, defines["documentation"]]
symlinks = {"Applications": "/Applications"}
hide = [".documentation"]
hide_extension = [app_name]
icon = defines["icon"]
background = defines["background"]

window_rect = ((160, 160), (760, 460))
show_toolbar = False
show_sidebar = False
show_status_bar = False
show_tab_view = False
show_pathbar = False
default_view = "icon-view"
include_icon_view_settings = True
include_list_view_settings = False
show_icon_preview = False
show_item_info = False
arrange_by = None
icon_size = 128
text_size = 14
label_pos = "bottom"
icon_locations = {app_name: (190, 180), "Applications": (570, 180)}
grid_spacing = 100
scroll_position = (0, 0)
