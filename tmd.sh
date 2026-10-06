#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 TheKimi7
# Shared library. Sourced by the entry-point scripts.

MODID=TrustMeDarling
MODDIR=${MODDIR:-/data/adb/modules/$MODID}
DATADIR=/data/adb/$MODID
LOGFILE=$DATADIR/log.txt
CONFIG=$DATADIR/config
STATEFILE=$DATADIR/state

SYS_STORE=/system/etc/security/cacerts
APEX_STORE=/apex/com.android.conscrypt/cacerts
MOD_STORE=$MODDIR$SYS_STORE

# --- environment ---

SDK=$(getprop ro.build.version.sdk)
case $SDK in '' | *[!0-9]*) SDK=0 ;; esac

# On a preview build ro.build.version.sdk still reports the previous API level.
CODENAME=$(getprop ro.build.version.codename)
[ "$CODENAME" = REL ] && IS_PREVIEW=0 || IS_PREVIEW=1

# Sourced, so shell assignments only. Keys: debug, force_late, force_walk.
force_late=0
force_walk=0
debug=0
[ -f "$CONFIG" ] && . "$CONFIG" 2>/dev/null

# --- output ---

log() {
    # The wall clock is usually unset during post-fs-data; uptime is not.
    printf '%s up=%-6s %s\n' \
        "$(date '+%m-%d %H:%M:%S' 2>/dev/null)" \
        "$(cut -d. -f1 /proc/uptime 2>/dev/null)" \
        "$*" >>"$LOGFILE" 2>/dev/null
}

logd() { [ "$debug" = 1 ] && log "  [debug] $*"; }

state_set() {
    mkdir -p "$DATADIR" 2>/dev/null
    printf '%s\n' "$*" >"$STATEFILE" 2>/dev/null
}

# One-line status under the module name in the manager's list.
describe() {
    [ -f "$MODDIR/module.prop" ] || return 0
    sed -i "s|^description=.*|description=$*|" "$MODDIR/module.prop" 2>/dev/null
}

# --- tooling ---

# Platform binaries first, the manager's busybox as a fallback for builds with
# a stripped toybox.
BUSYBOX=
for _b in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox \
    /data/adb/ap/bin/busybox /data/adb/modules/BuiltIn-BusyBox/system/bin/busybox; do
    [ -x "$_b" ] && { BUSYBOX=$_b; break; }
done
unset _b

resolve() {
    if command -v "$1" >/dev/null 2>&1; then
        printf '%s' "$1"
        return 0
    fi
    if [ -n "$BUSYBOX" ] && "$BUSYBOX" --list 2>/dev/null | grep -qx "$1"; then
        printf '%s %s' "$BUSYBOX" "$1"
        return 0
    fi
    return 1
}

NSENTER=$(resolve nsenter) || NSENTER=
MOUNT=$(resolve mount) || MOUNT=mount

# From disk layout: KSU/APATCH only set their env vars during installation.
manager() {
    if [ -d /data/adb/ksu ]; then
        printf 'KernelSU'
    elif [ -d /data/adb/ap ]; then
        printf 'APatch'
    elif command -v magisk >/dev/null 2>&1; then
        printf 'Magisk %s' "$(magisk -V 2>/dev/null)"
    else
        printf 'unknown'
    fi
}

# --- trust stores ---

# Same gate conscrypt uses: the apex store needs the directory *and* API 34+.
# An older device with an updated conscrypt module has the directory but still
# reads /system.
active_store() {
    if [ -d "$APEX_STORE" ] && [ "$SDK" -ge 34 ]; then
        printf '%s' "$APEX_STORE"
    else
        printf '%s' "$SYS_STORE"
    fi
}

needs_late_inject() {
    [ "$force_late" = 1 ] && return 0
    [ "$(active_store)" = "$APEX_STORE" ]
}

count_files() {
    _c=0
    for _f in "$1"/*; do [ -e "$_f" ] && _c=$((_c + 1)); done
    printf '%s' "$_c"
}

# All Android users, work profiles included. Never create cacerts-added: a
# root-owned one stops KeyChain (uid system) adding the first certificate.
list_user_certs() {
    for _d in /data/misc/user/*/cacerts-added; do
        [ -d "$_d" ] || continue
        for _f in "$_d"/*; do
            [ -f "$_f" ] || continue
            printf '%s\n' "$_f"
        done
    done
}

# Disabling a system CA records its alias under cacerts-removed, and the
# platform then suppresses that slot by name whatever the file contains.
is_removed_alias() {
    for _ra in /data/misc/user/*/cacerts-removed/"$1"; do
        [ -e "$_ra" ] && return 0
    done
    return 1
}

# Copy user certs into <dst>, renumbering around names already taken in <base>.
# Only user certs are renamed; a disabled system CA is matched by filename, so
# renaming a system cert would silently re-enable it.
stage_user_certs() {
    _dst=$1
    _base=$2
    : >"$DATADIR/.staged"
    : >"$DATADIR/.conflicts"
    list_user_certs | while IFS= read -r _src; do
        _name=${_src##*/}
        _hash=${_name%.*}
        # Start at 0 and take the first free slot, ignoring the suffix the
        # source file carries. Lookup tries <hash>.0, .1, .2 ... and stops at
        # the first index that does not exist, so a gap hides everything above
        # it with no error anywhere.
        _i=0
        _skip=0
        while :; do
            if [ -e "$_dst/$_hash.$_i" ]; then _i=$((_i + 1)); continue; fi
            if [ -e "$_base/$_hash.$_i" ]; then
                # Format differences defeat cmp, which at worst stages a
                # duplicate under the next suffix. It never drops a cert.
                if cmp -s "$_src" "$_base/$_hash.$_i"; then _skip=1; break; fi
                _i=$((_i + 1))
                continue
            fi
            break
        done
        if [ "$_skip" = 1 ]; then
            log "  already in base store: $_name"
            continue
        fi
        if cp -f "$_src" "$_dst/$_hash.$_i" 2>/dev/null; then
            if [ "$_hash.$_i" != "$_name" ]; then
                log "  renumbered $_name -> $_hash.$_i (subject hash collision)"
                log "    $_name is already taken in $_base"
                printf '%s %s %s\n' "$_name" "$_hash.$_i" "$_base" \
                    >>"$DATADIR/.conflicts"
            fi
            # Contiguity forces this slot, so a disabled alias here cannot be
            # worked around.
            if is_removed_alias "$_hash.$_i"; then
                log "  WARNING: $_hash.$_i is a disabled-CA alias."
                log "  The platform suppresses this slot by name, so this"
                log "  certificate will NOT be trusted. Re-enable that CA under"
                log "  Settings > Encryption & credentials > Trusted credentials."
            fi
            log "  staged $_hash.$_i"
            # On disk, not a variable: the loop body is a subshell.
            printf '%s\n' "$_hash.$_i" >>"$DATADIR/.staged"
        else
            log "  FAILED to stage $_name"
        fi
    done
}

staged_names() { cat "$DATADIR/.staged" 2>/dev/null; }
conflicts() { cat "$DATADIR/.conflicts" 2>/dev/null; }
conflict_count() { conflicts | grep -c '[0-9a-f]'; }
staged_count() { staged_names | grep -c '[0-9a-f]'; }

# Probe: a namespace that cannot see this has had our mounts stripped.
staged_marker() { staged_names | head -1; }

# Recorded separately because staging against the apex store can pick different
# suffixes, and those names would not exist under /system.
sys_marker() { head -1 "$DATADIR/.staged.sys" 2>/dev/null; }

fix_perms() {
    _dir=$1
    _ref=${2:-$(active_store)}
    chown 0:0 "$_dir" 2>/dev/null
    chmod 0755 "$_dir" 2>/dev/null
    chmod 0644 "$_dir"/* 2>/dev/null
    chown 0:0 "$_dir"/* 2>/dev/null
    # Timestamp from a certificate, not the directory: a store directory's own
    # mtime is set at mount time and is as skewed as the clock.
    for _t in "$_ref"/*; do
        [ -f "$_t" ] || continue
        touch -r "$_t" "$_dir" "$_dir"/* 2>/dev/null
        break
    done

    # Mode 644 makes ownership cosmetic; the label is what conscrypt needs.
    [ "$(getenforce 2>/dev/null)" = Enforcing ] || return 0
    _ctx=$(ls -Zd "$_ref" 2>/dev/null | awk '{print $1}')
    case $_ctx in '' | '?' | /*) _ctx=u:object_r:system_security_cacerts_file:s0 ;; esac
    chcon "$_ctx" "$_dir" 2>/dev/null
    chcon "$_ctx" "$_dir"/* 2>/dev/null
}

# --- processes ---

# PPid from status, not stat, whose comm field can contain spaces and brackets.
proc_table() {
    if command -v awk >/dev/null 2>&1; then
        awk '/^PPid:/ { split(FILENAME, a, "/"); print a[3], $2 }' \
            /proc/[0-9]*/status 2>/dev/null && return 0
    fi
    for _s in /proc/[0-9]*/status; do
        _p=${_s#/proc/}
        _p=${_p%/status}
        _pp=$(sed -n 's/^PPid:[[:space:]]*//p' "$_s" 2>/dev/null)
        [ -n "$_pp" ] && printf '%s %s\n' "$_p" "$_pp"
    done
}

# USAP pool members keep the zygote's name until they specialise, so pidof
# alone also returns processes about to become apps. A real zygote's parent is
# init.
zygote_pids() {
    for _n in zygote zygote64; do
        for _p in $(pidof "$_n" 2>/dev/null); do
            case $_p in '' | *[!0-9]*) continue ;; esac
            _pp=$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$_p/status" 2>/dev/null)
            [ "$_pp" = 1 ] && printf '%s\n' "$_p"
        done
    done | sort -u
}

# Mixed-ABI builds run two. Missing the secondary one leaves every app of that
# ABI untrusted.
expected_zygotes() {
    case $(getprop ro.zygote) in
    *_*) printf 2 ;;
    *) printf 1 ;;
    esac
}

# Transitive, to reach app_zygote and webview_zygote children.
descendants_of() {
    _table=$(proc_table)
    _frontier=$*
    _seen=
    while [ -n "$_frontier" ]; do
        _next=
        for _p in $_frontier; do
            case " $_seen " in *" $_p "*) continue ;; esac
            _seen="$_seen $_p"
            _next="$_next $(printf '%s\n' "$_table" | awk -v pp="$_p" '$2==pp {print $1}')"
        done
        _frontier=$_next
    done
    printf '%s\n' $_seen
}

ns_of() { readlink "/proc/$1/ns/mnt" 2>/dev/null; }

ns_sees() {
    [ -n "$NSENTER" ] || return 1
    $NSENTER --mount="/proc/$1/ns/mnt" -- test -e "$2" 2>/dev/null
}

has_mount_at() {
    [ -r "/proc/$1/mountinfo" ] || return 1
    awk -v t="$2" '$5 == t { found = 1 } END { exit !found }' "/proc/$1/mountinfo"
}

# --- hiding layers ---

# Shamiko reads Magisk's DenyList but needs enforcement switched off, so a
# populated list with enforcement 0 is its normal configuration. An empty
# /data/adb/shamiko/whitelist inverts it to hide from all but the list.
hide_report() {
    command -v magisk >/dev/null 2>&1 || { printf 'unknown'; return 0; }
    _enforce=$(magisk --sqlite "select value from settings where key='denylist'" 2>/dev/null)
    _enforce=${_enforce#value=}
    _list=$(magisk --denylist ls 2>/dev/null | cut -d'|' -f1 | sort -u | grep -v '^isolated$')
    _count=$(printf '%s\n' "$_list" | grep -c '[a-z]')
    _shamiko=0
    [ -d /data/adb/modules/zygisk_shamiko ] &&
        [ ! -f /data/adb/modules/zygisk_shamiko/disable ] && _shamiko=1
    _whitelist=0
    [ -f /data/adb/shamiko/whitelist ] && _whitelist=1

    if [ "$_shamiko" = 1 ] && [ "$_whitelist" = 1 ]; then
        printf 'shamiko-whitelist %s' "$_count"
    elif [ "$_shamiko" = 1 ]; then
        printf 'shamiko-blacklist %s' "$_count"
    elif [ "$_enforce" = 1 ]; then
        printf 'denylist-enforced %s' "$_count"
    else
        printf 'none %s' "$_count"
    fi
}

hidden_packages() {
    command -v magisk >/dev/null 2>&1 || return 0
    magisk --denylist ls 2>/dev/null | cut -d'|' -f1 | sort -u | grep -v '^isolated$'
}
