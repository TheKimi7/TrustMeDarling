#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 TheKimi7
#
# Android 14+ only does any work here. From 14 the trust store lives inside the
# read-only conscrypt APEX, which the module tree cannot reach, so the merged
# store is mounted over it after apexd and zygote are up.

MODDIR=${0%/*}
# $0 is not always a path; fall back so the library always loads.
[ -f "$MODDIR/tmd.sh" ] || MODDIR=/data/adb/modules/TrustMeDarling
. "$MODDIR/tmd.sh"

STAGE=/dev/.tmd_store

# Our own tmpfs is a single flat mount, so a plain bind is enough. Binding the
# module-mounted /system store would need --rbind, since a manager can mount
# each cert file individually and a plain bind drops those nested mounts.
build_stage() {
    _target=$1
    umount "$STAGE" 2>/dev/null
    mkdir -p "$STAGE" 2>/dev/null
    mount -t tmpfs tmd_store "$STAGE" 2>/dev/null || {
        log "  FAILED: cannot mount tmpfs at $STAGE"
        return 1
    }
    cp -f "$_target"/* "$STAGE"/ 2>/dev/null
    _base=$(count_files "$STAGE")
    stage_user_certs "$STAGE" "$_target"
    fix_perms "$STAGE" "$_target"
    log "  stage built: $_base base + $(staged_count) user = $(count_files "$STAGE") certs"
    [ "$(count_files "$STAGE")" -gt 0 ]
}

bind_in() {
    # Via nsenter even for init: this script's own namespace is not guaranteed
    # to be init's.
    if [ -n "$NSENTER" ]; then
        $NSENTER --mount="/proc/$1/ns/mnt" -- $MOUNT -o bind "$STAGE" "$2" 2>/dev/null
    elif [ "$1" = 1 ]; then
        $MOUNT -o bind "$STAGE" "$2" 2>/dev/null
    else
        return 1
    fi
}

# The binds keep the tmpfs alive. Dropping the staging path removes a mount
# entry every process on the device would otherwise inherit.
release_stage() {
    umount "$STAGE" 2>/dev/null && rmdir "$STAGE" 2>/dev/null
}

inject_late() {
    _target=$1
    build_stage "$_target" || return 1

    _probe=$(sys_marker)
    [ -n "$_probe" ] && logd "namespace probe: $SYS_STORE/$_probe"

    # init first. Where /apex propagates init -> zygote as a slave mount, this
    # covers everything on its own.
    if [ "$force_walk" = 1 ]; then
        log "  force_walk=1: skipping the init bind to exercise the walk"
    elif bind_in 1 "$_target"; then
        log "  bound into init namespace"
    else
        log "  WARNING: bind into init namespace failed"
    fi

    _zygotes=$(zygote_pids)
    if [ -z "$_zygotes" ]; then
        log "  WARNING: no zygote found"
        return 1
    fi

    # By result, not by parsing propagation flags.
    _propagated=1
    [ "$force_walk" = 1 ] && _propagated=0
    for _z in $_zygotes; do
        has_mount_at "$_z" "$_target" || _propagated=0
    done
    if [ "$_propagated" = 1 ]; then
        log "  propagated to zygote automatically - no namespace injection needed"
        release_stage
        verify_late "$_target" "$_zygotes"
        return $?
    fi

    log "  no propagation to zygote - injecting per namespace"

    # Zygotes first, before enumerating anything. descendants_of walks the
    # whole process table, which takes tens of seconds on a device with GApps,
    # and every app forked during that window would otherwise inherit an
    # unpatched namespace and never be revisited.
    for _z in $_zygotes; do
        has_mount_at "$_z" "$_target" && continue
        bind_in "$_z" "$_target" && log "  zygote $_z bound first" ||
            logd "zygote $_z bind failed"
    done

    _done_ns=
    _ok=0
    _skipped=0
    for _p in $(descendants_of $_zygotes); do
        [ -d "/proc/$_p" ] || continue
        _ns=$(ns_of "$_p")
        [ -n "$_ns" ] || continue
        # By namespace, not pid: children share one, so per-pid would stack
        # mounts.
        case " $_done_ns " in *" $_ns "*) continue ;; esac

        # A namespace that cannot see our staged cert in /system has had the
        # module's mounts reverted, which only happens when the user runs
        # root-hiding. Re-mounting there would undo what they asked for.
        if [ -n "$_probe" ] && ! ns_sees "$_p" "$SYS_STORE/$_probe"; then
            logd "skipping reverted namespace $_ns (pid $_p)"
            _skipped=$((_skipped + 1))
            _done_ns="$_done_ns $_ns"
            continue
        fi

        if has_mount_at "$_p" "$_target"; then
            _done_ns="$_done_ns $_ns"
            continue
        fi
        if bind_in "$_p" "$_target"; then
            _ok=$((_ok + 1))
        else
            logd "bind failed for pid $_p (ns $_ns)"
        fi
        _done_ns="$_done_ns $_ns"
    done
    log "  injected into $_ok namespace(s), skipped $_skipped reverted"
    release_stage
    verify_late "$_target" "$_zygotes"
}

# Zygote's view is what every app forked afterwards inherits, so that is what
# gets checked.
verify_late() {
    _target=$1
    _marker=$(staged_marker)
    [ -n "$_marker" ] || return 0
    _seen=0
    _total=0
    for _z in $2; do
        _total=$((_total + 1))
        if ns_sees "$_z" "$_target/$_marker"; then
            _seen=$((_seen + 1))
            log "  verified: zygote $_z sees $_marker in $_target"
        else
            log "  VERIFY FAILED: zygote $_z cannot see $_marker in $_target"
        fi
    done
    _want=$(expected_zygotes)
    if [ "$_total" -lt "$_want" ]; then
        log "  WARNING: found $_total zygote(s), ro.zygote implies $_want."
        log "  Apps of the other ABI may not be covered."
    fi
    # All of them: one uncovered zygote means every app of that ABI misses out.
    [ "$_total" -gt 0 ] && [ "$_seen" = "$_total" ]
}

main() {
    log "TrustMeDarling! - service"

    # late_start is non-blocking, so the boot may still be in progress.
    _w=0
    while [ "$(getprop sys.boot_completed)" != 1 ] && [ "$_w" -lt 120 ]; do
        sleep 1
        _w=$((_w + 1))
    done

    if [ "$(staged_count)" = 0 ]; then
        log "  nothing staged - idle"
        exit 0
    fi

    _conf=""
    [ "$(conflict_count)" -gt 0 ] &&
        _conf=" $(conflict_count) renamed on collision."

    if needs_late_inject; then
        _target=$(active_store)
        [ "$force_late" = 1 ] && [ "$SDK" -lt 34 ] && _target=$SYS_STORE
        log "Late injection into $_target"
        if inject_late "$_target"; then
            describe "Active - $(staged_count) cert(s) in the conscrypt APEX store.$_conf"
        else
            log "  late injection incomplete - see above"
            describe "FAILED - certificates are not trusted. See the log."
        fi
    else
        # Nothing to mount: the module tree is already part of /system.
        if [ -e "$SYS_STORE/$(staged_marker)" ]; then
            log "Module mount active: $(staged_count) cert(s) in $SYS_STORE"
            describe "Active - $(staged_count) cert(s) in the system store.$_conf"
        else
            log "WARNING: staged certs are not visible in $SYS_STORE"
            log "  the root manager may not have mounted the module tree"
            describe "FAILED - certificates are not trusted. See the log."
        fi
    fi

    log "Done."
}

main
