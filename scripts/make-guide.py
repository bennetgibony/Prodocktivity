#!/usr/bin/env python3
"""Builds Resources/Setup Guide.html from guide.template.html with the images embedded.
Only neutral images (app icon, icon set) are used, so the guide holds no personal data."""
import base64, pathlib
root = pathlib.Path(__file__).resolve().parent.parent / "Resources"
t = (root / "guide.template.html").read_text()
icon = "data:image/png;base64," + base64.b64encode((root / "guide-appicon.png").read_bytes()).decode()
shot = "data:image/png;base64," + base64.b64encode((root / "guide-icons.png").read_bytes()).decode()
page = t.replace("__ICON__", icon).replace("__SHOT__", shot)
(root.parent / "build").mkdir(exist_ok=True)
(root.parent / "build" / "setup-guide-artifact.html").write_text(page)
local = ('<!doctype html>\n<html lang="en"><head><meta charset="utf-8">'
         '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
         + page.replace("</style>", "</style>\n</head><body>", 1) + "\n</body></html>\n")
(root / "Setup Guide.html").write_text(local)
# The "What's new" page, built the same way.
news = (root / "whats-new.template.html").read_text().replace("__ICON__", icon)
(root / "What's New.html").write_text('<!doctype html>\n<html lang="en"><head><meta charset="utf-8">'
    '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
    + news.replace("</style>", "</style>\n</head><body>", 1) + "\n</body></html>\n")
print("guide written")
