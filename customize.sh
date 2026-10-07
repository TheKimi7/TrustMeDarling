#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 TheKimi7
# Sourced by the installer; must not call exit.

SKIPUNZIP=0

ui_print "- TrustMeDarling!"
ui_print "  android sdk : $API"
ui_print "  architecture: $ARCH"

# API 30 is the floor: below it /bin/mount and the rootdir symlinks are absent.
# Nothing else is gated here - the live trust store is detected at runtime.
if [ "$API" -lt 30 ]; then
    abort "! Requires Android 11 (API 30) or newer. Found API $API."
fi

if [ -d /apex/com.android.conscrypt/cacerts ] && [ "$API" -ge 34 ]; then
    ui_print "  trust store : conscrypt APEX (late injection)"
else
    ui_print "  trust store : /system (module mount)"
fi

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/tmd.sh" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755

ui_print ""
ui_print "- Reboot, then install a CA via Settings >"
ui_print "  Security > Encryption & credentials."
ui_print "- Status: /data/adb/TrustMeDarling/log.txt, and the"
ui_print "  one-line summary under the module name."
