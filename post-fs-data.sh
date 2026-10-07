#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 TheKimi7
# Stages user certs into the module tree before the manager mounts it, so they
# turn up in /system/etc/security/cacerts without mounting anything here.

MODDIR=${0%/*}
# $0 is not always a path; fall back so the library always loads.
[ -f "$MODDIR/tmd.sh" ] || MODDIR=/data/adb/modules/TrustMeDarling
. "$MODDIR/tmd.sh"

mkdir -p "$DATADIR" 2>/dev/null
: >"$LOGFILE"

log "TrustMeDarling! - post-fs-data"
log "  sdk=$SDK codename=$CODENAME preview=$IS_PREVIEW manager=$(manager)"
log "  active store: $(active_store)"

# Rebuilt every boot, so deleted certs actually disappear.
rm -rf "$MOD_STORE"

if [ -z "$(list_user_certs)" ]; then
    log "  no user certificates installed - nothing to do"
    # No system/ directory means no files to mount and no mounts at all.
    rmdir -p "${MOD_STORE%/*}" 2>/dev/null
    : >"$DATADIR/.staged"
    : >"$DATADIR/.staged.sys"
    describe "Idle - no user certificates installed."
    exit 0
fi

mkdir -p "$MOD_STORE"

# User certs only. Managers merge directory contents with the real /system, so
# copying the system certs in too would add nothing and would rename files that
# cacerts-removed matches by name.
log "Staging user certificates"
stage_user_certs "$MOD_STORE" "$SYS_STORE"
fix_perms "$MOD_STORE" "$SYS_STORE"

# service.sh probes for these names to tell which namespaces still carry the
# module mount.
cp -f "$DATADIR/.staged" "$DATADIR/.staged.sys" 2>/dev/null

log "  staged $(staged_count) certificate(s)"

if needs_late_inject; then
    if [ "$force_late" = 1 ]; then
        log "  force_late=1 - service.sh will inject (debug)"
    else
        log "  conscrypt apex store is authoritative - service.sh will inject"
    fi
else
    log "  /system store is authoritative - the module mount covers it"
fi
