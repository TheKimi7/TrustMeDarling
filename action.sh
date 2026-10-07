#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 TheKimi7
#
# Reports whether the certificates are actually trusted, measured from inside
# each running app's mount namespace rather than assumed.

MODDIR=${0%/*}
# $0 is not always a path; fall back so the library always loads.
[ -f "$MODDIR/tmd.sh" ] || MODDIR=/data/adb/modules/TrustMeDarling
. "$MODDIR/tmd.sh"

say() { echo "$@"; }

STORE=$(active_store)
MARK=$(staged_marker)

say "TrustMeDarling!"
say "  android     : $SDK${CODENAME:+ ($CODENAME)}"
say "  manager     : $(manager)"
say "  trust store : $STORE"
say ""

if [ "$(staged_count)" = 0 ]; then
    say "No user certificates installed."
    say "Add one under Settings > Security > Encryption & credentials >"
    say "Install a certificate > CA certificate, then reboot."
    exit 0
fi

say "Certificates added by this module ($(staged_count)):"
staged_names | while IFS= read -r c; do say "  $c"; done
say ""

if [ "$(conflict_count)" -gt 0 ]; then
    say "Renamed to avoid a collision:"
    conflicts | while read -r want got base; do
        say "  $want was taken in $base, staged as $got"
    done
    say "  Both are offered to the platform. Android resolves a subject hash by"
    say "  trying .0, .1, .2 ... so a renamed certificate is equally trusted."
    say ""
fi

if [ -e "$STORE/$MARK" ]; then
    say "Store: OK - $(count_files "$STORE") certificates in $STORE"
else
    say "Store: FAILED - $MARK is missing from $STORE"
    say "  See $LOGFILE"
fi
say ""

if [ -z "$NSENTER" ]; then
    say "nsenter unavailable, so per-app checks cannot run."
    exit 0
fi

# Apps only: uid >= 10000 and a package-shaped name. One awk pass over
# /proc/*/status; a sed per process costs ~9s on a busy device, long enough
# that a host UI gives up and shows nothing.
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

say "Per-app check - trusted, measured per running app:"
OK=0
BAD=0
BADLIST=
for pid in $(app_pids); do
    [ -d "/proc/$pid" ] || continue
    name=$(tr -d '\0' < "/proc/$pid/cmdline" 2>/dev/null)
    case $name in *.*) ;; *) continue ;; esac
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

say "  $OK app(s) trust the certificates"
if [ "$BAD" -gt 0 ]; then
    say "  $BAD app(s) do NOT:"
    for n in $BADLIST; do say "    $n"; done
    say ""
    say "  The usual cause is root-hiding: Shamiko, a DenyList or KernelSU's"
    say "  umount revert this module's mounts inside the apps they hide, so the"
    say "  certificate is absent there and nowhere else. Exempt the app you are"
    say "  testing, then force-stop it."
fi
