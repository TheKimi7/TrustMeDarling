#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 TheKimi7
# Status report, wired to the manager's Action button. Checks the trust store
# the way apps actually see it, by entering each app's mount namespace, rather
# than predicting from config.

MODDIR=${0%/*}
# ${0%/*} yields "sh" when $0 carries no slash, which happens when a host
# sources this instead of executing it.
[ -f "$MODDIR/tmd.sh" ] || MODDIR=/data/adb/modules/TrustMeDarling
. "$MODDIR/tmd.sh"

say() { echo "$@"; }

STORE=$(active_store)
MARK=$(staged_marker)
PROBE=$(sys_marker)

say "TrustMeDarling"
say "  android      : $SDK${CODENAME:+ ($CODENAME)}"
say "  root manager : $(manager)"
say "  trust store  : $STORE"
say "  selinux      : $(getenforce 2>/dev/null)"
say ""

if [ "$(staged_count)" = 0 ]; then
    say "No user certificates are installed."
    say "Install one via Settings > Security > Encryption & credentials,"
    say "then reboot."
    exit 0
fi

say "Staged by this module ($(staged_count)):"
staged_names | while IFS= read -r c; do say "  $c"; done
say ""

if [ "$(conflict_count)" -gt 0 ]; then
    say "Name conflicts ($(conflict_count)):"
    conflicts | while read -r want got base; do
        say "  $want was already present in $base"
        say "    -> this module staged its copy as $got instead"
    done
    say ""
    say "  Both are offered to the platform, so this is usually harmless."
    say "  It only matters when the existing one is stale - an old CA with the"
    say "  same subject but a different key, which cannot validate anything."
    say "  To inspect or remove the existing one (it lives on the read-only"
    say "  system partition, which the module cannot touch):"
    say ""
    say "    # from a recovery adb shell, or Android with /system remounted rw"
    say "    mount -o rw /dev/block/by-name/system /mnt/sys"
    say "    ls -l /mnt/sys/system/etc/security/cacerts/<hash>.*"
    say "    rm /mnt/sys/system/etc/security/cacerts/<hash>.0"
    say "    mount -o ro,remount /mnt/sys"
    say ""
    say "  Do NOT leave a gap in the sequence: the platform tries <hash>.0,"
    say "  .1, .2 ... and stops at the first one missing, so removing .0 while"
    say "  .1 exists hides both. Reboot after changing anything; the module"
    say "  re-stages into the lowest free slot."
    say ""
fi

if [ -e "$STORE/$MARK" ]; then
    say "Global view: OK - $(count_files "$STORE") certs in $STORE"
else
    say "Global view: FAILED - $MARK is missing from $STORE"
    say "  The module tree was not mounted. Check $LOGFILE."
fi
say ""

# Apps only: uid >= 10000 and a package-shaped name.
if [ -z "$NSENTER" ]; then
    say "nsenter is unavailable, so per-app checks cannot run."
    exit 0
fi

# Visibility, not an actual handshake.
say "Per-app check - certificate visibility, running apps only:"
OK=0
BAD=0
BADLIST=
# One awk pass over /proc/*/status. A sed per process costs ~9.5s here, long
# enough that a host UI gives up and shows nothing.
app_pids() {
    if command -v awk >/dev/null 2>&1; then
        awk '/^Uid:/ { split(FILENAME, a, "/"); if ($2 + 0 >= 10000) print a[3] }' \
            /proc/[0-9]*/status 2>/dev/null && return 0
    fi
    for _s in /proc/[0-9]*/status; do
        _p=${_s#/proc/}; _p=${_p%/status}
        _u=$(sed -n 's/^Uid:[[:space:]]*\([0-9]*\).*/\1/p' "$_s" 2>/dev/null)
        [ -n "$_u" ] && [ "$_u" -ge 10000 ] 2>/dev/null && printf '%s\n' "$_p"
    done
}

for pid in $(app_pids); do
    [ -d "/proc/$pid" ] || continue
    name=$(tr -d '\0' < "/proc/$pid/cmdline" 2>/dev/null)
    case $name in
    *.*) ;;
    *) continue ;;
    esac
    # Child processes share the namespace; report each package once.
    case " $SEEN " in *" $name "*) continue ;; esac
    SEEN="$SEEN $name"
    if $NSENTER --mount="/proc/$pid/ns/mnt" -- test -e "$STORE/$MARK" 2>/dev/null; then
        OK=$((OK + 1))
    else
        BAD=$((BAD + 1))
        BADLIST="$BADLIST $name"
    fi
done

say "  $OK app(s) can see the certificates"
if [ "$BAD" -gt 0 ]; then
    say "  $BAD app(s) can NOT:"
    for n in $BADLIST; do say "    $n"; done
    say ""
    set -- $(hide_report)
    case $1 in
    shamiko-whitelist)
        say "  Cause: Shamiko is in whitelist mode, which hides root from"
        say "  almost everything. Delete /data/adb/shamiko/whitelist and"
        say "  reboot to return to blacklist mode."
        ;;
    shamiko-blacklist)
        say "  Cause: Shamiko strips module mounts in DenyList apps."
        say "  Untick only the app you are intercepting, under"
        say "  Magisk > Settings > Configure DenyList, then force-stop it."
        say "  Leave gms/vending listed if you rely on Play Integrity."
        ;;
    denylist-enforced)
        say "  Cause: Magisk DenyList enforcement is on. Untick only the"
        say "  app you are intercepting; leave gms/vending listed if you"
        say "  rely on Play Integrity."
        ;;
    none)
        say "  No hiding layer was detected, so this is unexpected."
        say "  Please attach $LOGFILE when reporting it."
        ;;
    *)
        say "  No denylist could be read (no magisk CLI), so the cause is"
        say "  unknown. A hiding layer may still be active."
        ;;
    esac
fi
