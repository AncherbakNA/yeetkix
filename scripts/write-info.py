#!/usr/bin/env python3
"""Create bundle metadata. Update configuration is optional and fails closed."""
import base64
import os
import plistlib
import re
import sys
from urllib.parse import urlparse

info = {
    "CFBundleName": "Yeetkix", "CFBundleDisplayName": "YEETKIX", "CFBundleExecutable": "Yeetkix",
    "CFBundleIdentifier": "local.luma.cleaner", "CFBundleVersion": os.environ.get("YEETKIX_BUILD", "8"),
    "CFBundleShortVersionString": os.environ.get("YEETKIX_VERSION", "1.0"), "CFBundlePackageType": "APPL",
    "CFBundleIconFile": "AppIcon", "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True,
    "NSPrincipalClass": "NSApplication", "SUEnableAutomaticChecks": False,
    "SUAutomaticallyUpdate": False, "SUEnableSystemProfiling": False, "SUVerifyUpdateBeforeExtraction": True,
}
if not re.fullmatch(r"\d+(?:\.\d+){0,2}", info["CFBundleShortVersionString"]) or not re.fullmatch(r"[1-9]\d*", info["CFBundleVersion"]):
    sys.exit("Version must have 1-3 numeric components; build must be a positive integer")
for folder, russian in [("Downloads", "Загрузки"), ("Documents", "Документы"), ("Desktop", "Рабочий стол"), ("Pictures", "Изображения"), ("Music", "Музыка")]:
    info[f"NS{folder}FolderUsageDescription"] = f"YEETKIX проверяет выбранные файлы в папке «{russian}». Перенос в Корзину — только после вашего выбора и подтверждения."
feed, key = os.environ.get("YEETKIX_UPDATE_FEED", ""), os.environ.get("YEETKIX_UPDATE_PUBLIC_KEY", "")
if feed or key:
    parsed = urlparse(feed)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.fragment:
        sys.exit("YEETKIX_UPDATE_FEED must be an HTTPS URL without credentials or fragment")
    try:
        if len(base64.b64decode(key, validate=True)) != 32: raise ValueError()
    except Exception:
        sys.exit("YEETKIX_UPDATE_PUBLIC_KEY must be a base64 Ed25519 public key (32 bytes)")
    info.update(SUFeedURL=feed, SUPublicEDKey=key)
with open(sys.argv[1], "wb") as output:
    plistlib.dump(info, output, sort_keys=False)
