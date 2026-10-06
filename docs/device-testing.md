# On-device test results — 2026-10-06

## Test device

Redmi 6 Pro (sakura), `aosp_sakura`, **Android 13 / SDK 33**, codename `REL`,
`ro.build.type=user` (fingerprint says `userdebug/release-keys`),
`arm64-v8a,armeabi-v7a,armeabi`, `ro.zygote=zygote64_32`,
`ro.apex.updatable` empty → **flattened APEX**.
Magisk 30.7 (`MAGISKTMP=/debug_ramdisk`), SELinux **Enforcing**.
`/apex/com.android.conscrypt/cacerts` → **ABSENT**, so the A14+ code path is
unreachable on this hardware.

Modules present: BuiltIn-BusyBox, charch_sshd (disabled), hosts, nano-ndk,
playintegrityfix, tricky_store (disabled), zygisk-ssl-unpinning (**disabled** —
confirmed not a confounder), **zygisk_shamiko v1.2.5**, zygisk_vector.

## Magic-mount topology on Magisk 30.7

`/system/etc` is a Magisk **tmpfs skeleton** (dev `0:22`, source `magisk`),
`shared:10` in init's namespace and `master:10` (slave) in both zygotes. All 130
original cert files are bind-mounted back in individually from the system block
device. 1601 total `/system` mounts: `lib64` 656, `lib` 361, `bin` 200,
`etc/security/cacerts` 130, `etc/init` 58.

Consequences:

- "Cert files are mountpoints" is a **Magisk magic-mount artifact**, not an
  Android 15 behaviour. It appears on any version as soon as another module
  writes under `/system/etc` (here: `hosts` and `nano-ndk`).
- Any design layered on magic mount therefore needs `--rbind`, not `--bind`.
- Magisk's official guide confirms `post-fs-data.sh` runs **before** modules are
  mounted, explicitly so modules can adjust themselves. Staging there is
  therefore sound, and manager-independence is not the problem to solve.

## Test 1 — baseline, legacy path → WORKS

A throwaway CA was installed to `/data/misc/user/0/cacerts-added`
(`system:system`, `644`, `u:object_r:misc_user_data_file:s0`), then reboot.
Module log collected the cert, reported `No conscrypt`, then
`Finished injecting certs`. Module mirror: 131 certs. Global
`/system/etc/security/cacerts`: 131, test cert present.

**The module is not broken on this device.**

## Test 2 — per-process visibility → ROOT CAUSE

| process | denylisted | `/system/etc` mounts | certs | test CA |
|---|---|---|---|---|
| `com.android.chrome` | yes | 0 | 130 | **ABSENT** |
| `com.android.settings` | no | 1 | 131 | PRESENT |
| `com.android.systemui` | no | 1 | 131 | PRESENT |

Magisk DenyList *enforcement* is `0`, but the list is populated and
`/data/adb/shamiko/` holds no whitelist file → **Shamiko blacklist mode**: it
reverts module mounts in every denylisted process. Denylist: `com.android.chrome`,
`com.android.vending`, `com.google.android.gms`, `com.google.android.googlequicksearchbox`,
`com.google.android.inputmethod.latin`, `com.google.android.marvin.talkback`,
`com.google.android.odad`, `com.google.ar.core`, `com.shaya.android`, `isolated`.

This explains the reported "no module worked": testing happened in Chrome.
Flashing the CA into real `/system` from recovery worked because a file on disk
has no mount to strip.

## Test 3 — self-owned tmpfs bound into the zygote namespaces → STRIPPED

`mount -t tmpfs tmdcerts /dev/tmd_certs` (131 certs, relabelled
`u:object_r:system_security_cacerts_file:s0`), `--rbind` into both zygotes: both OK. Fresh Chrome after force-stop: 130 certs, test CA **absent**.

## Test 4 — post-spawn re-injection into a live process → WORKS

```
nsenter --mount=/proc/<chrome>/ns/mnt -- mount --rbind /dev/tmd_certs /system/etc/security/cacerts
before: 130 certs → after: 131 certs, test CA PRESENT, cacerts mountcount=1
```

A single clean mount, because Shamiko had already removed the Magisk skeleton, so
no parent remained to be detached. Shamiko acts at specialization only.

## Test 5 — neutral-path probe → disambiguates Test 3

Test 3 had two possible causes: (a) the mount was a child of `/system/etc` and
died when Shamiko detached that skeleton, or (b) Shamiko strips *anything* added
after its snapshot. A tmpfs at `/apex/tmd_probe` — outside `/system`, not a child
of any Magisk mount, device name `tmdprobe` — was mounted into both zygotes:

| process | denylisted | probe mount | result |
|---|---|---|---|
| `com.android.chrome` | yes | 0 | **STRIPPED** |
| `com.android.settings` | no | 1 | SURVIVED |

**(b) is correct.** Shamiko reverts to a clean mount snapshot and strips every
later addition regardless of path, parent or device name.

Consequences:

- Owning the tmpfs is **not** sufficient, on any Android version.
- On A14+, a self-owned tmpfs at `/apex/com.android.conscrypt/cacerts` would be
  stripped in denylisted apps too. Do not assume the apex path escapes this.
- For denylisted apps, **post-spawn re-injection is the only mount-based route**.

## Not verified

- **End-to-end TLS trust.** No `curl`/`openssl`/`wget` on device; no `javac` or
  Android SDK locally, so no dex TLS client could be built. Needs Burp against a
  target that uses platform TLS — *not* Chrome, which may use the Chrome Root
  Store and bypass the system store entirely.
- **Whether conscrypt honours a cert injected after process start**, and whether
  re-injection can win against apps that do TLS at launch. If it loses that race,
  the only reliable fix is a Zygisk hook running after Shamiko, which means
  native code and gives up the architecture-agnostic property.
- **Any A14+/conscrypt behaviour.** Needs an API 34–36 image.

## Learned during cleanup

Magisk 30 copies module-*added* files directly **into** the tmpfs skeleton rather
than bind-mounting each one. `grep bb7e9882 /proc/1/mountinfo` was empty and
`umount` returned `EINVAL`. Deleting a cert from the module mirror therefore has
**no effect until reboot**, which constrains any live-sync and `uninstall.sh`
design.

## Device state

Test CA removed from the user store, the module mirror and the live store
(verified gone from every namespace after reboot); private key material
destroyed. All probe mounts removed. Trust store back to 130 certs.

**The unmodified v1.3 module is still installed and active** at
`/data/adb/modules/TrustMeDarling`.

---

# v2.0 verification — same device, 2026-10-06

Four reboots on the Redmi 6 Pro described above (Android 13 / SDK 33,
Magisk 30.7, Shamiko blacklist mode).

## Inert when there are no user certs

No `system/` directory is created at all, so the root manager mounts nothing and
the module contributes no mounts. `description` reads
`Idle - no user certificates installed.` Live store: 130.

## Directory merging — copying the system store is unnecessary

Staged **only** the user certs. Module tree held 2 files; the live store showed
**132 = 130 + 2**. Every root manager merges module directories with the real
`/system`, so copying the ~130 system certs into the module adds nothing. Not copying them also means system cert filenames are never
renumbered, which matters because a CA disabled by the user is matched by name
in `cacerts-removed`.

## Subject-hash collision renumbering

A user cert deliberately named `4be590e0.0` — a name the system store already
uses — was renumbered:

```
renumbered 4be590e0.0 -> 4be590e0.1 (subject hash collision)
```

The system's own `4be590e0.0` was left byte-identical and untouched. Android
resolves a subject hash by trying `.0`, `.1`, `.2` …, so the renumbered cert is
equally trusted. Overwriting instead would silently lose the certificate.

## Certificate formats

Both were staged correctly: one **DER** (883 bytes, the format KeyChain writes
via `cert.getEncoded()`) and one PEM-plus-text (4352 bytes).

## Deletion propagates

Removing both certs from `cacerts-added` and rebooting returned the live store
to exactly **130**, with both staged files gone and the original system cert
intact. The module went back to inert.

## Diagnostics

Boot-time report, from config:

```
Hiding: Shamiko in blacklist mode, 9 package(s) listed.
  These apps will NOT see the certificates:
    com.android.chrome
    com.android.vending
    com.google.android.gms
    ... (9 total)
  Untick an app in Magisk's DenyList to let it see them.
```

`action.sh` (module Action button), measured per live process rather than
predicted:

```
Global view: OK - 132 certs in /system/etc/security/cacerts
Per-app check (running apps only):
  13 app(s) trust the certificates
  2 app(s) do NOT:
    com.google.android.gms.persistent
    com.google.android.gms
  Cause: Shamiko strips module mounts in DenyList apps.
```

## Fixed during testing

- `stage_user_certs` ran in a subshell (piped input), so its counter was lost.
  Staged names are recorded on disk instead.
- The hidden-namespace probe used a name staged against the apex store, which
  need not exist under `/system`; a separate `/system` marker is recorded.
- Certificate mtimes were stamped 1970 because the wall clock is unset during
  post-fs-data. `touch -r` against the reference store now matches it.

## Still not verified

- **End-to-end TLS trust.** Mount and filesystem visibility are proven; an
  actual handshake is not. Needs Burp against a non-Chrome target.
- **The KeyChain UI path.** Android requires a screen lock to install a CA
  through Settings, which was not set on the test device. The DER format
  KeyChain produces was tested; the UI flow itself was not.
- **The API 34+ apex path in `service.sh`.** No reachable hardware. It is
  feature-gated, verified by result, and fails loudly rather than silently.
  `force_late=1` in `/data/adb/TrustMeDarling/config` runs that code against
  `/system/etc/security/cacerts` on an older device to exercise the namespace
  walk, dedupe and skip-hidden logic.

---

# v2.0 — installer and late-path verification

## Real installer

Installed from a built zip with `magisk --install-module`, so `update-binary`
and `customize.sh` both ran for real:

```
- Device is system-as-root
*******************
 Trust Me Darling!
 by TheKimi7
*******************
- TrustMeDarling
  android sdk : 33
  architecture: arm64
  trust store : /system (module mount)
! Shamiko is installed.
  Apps on your DenyList will NOT see these certificates.
```

`$API` and `$ARCH` resolved, `set_perm`/`set_perm_recursive` succeeded, and the
Shamiko warning fired at install time.

## Exercising the API 34+ code path on an API 33 device

`force_late=1` makes `service.sh` run its late-injection logic against
`/system/etc/security/cacerts`, and `force_walk=1` additionally skips the init
bind so the per-namespace walk cannot be short-circuited by propagation. Both
are debug-only.

**`force_late=1`** — the init bind propagated, as the earlier `shared:10` →
`master:10` measurement predicted:

```
bound into init namespace
propagated to zygote automatically - no namespace injection needed
verified: zygote 1264 sees 8b8cba7d.1
```

SELinux label on the staged cert came out as
`u:object_r:system_security_cacerts_file:s0`, identical to a system cert, and
`logcat | grep avc` was empty.

**`force_walk=1`** — the walk, dedupe, skip-hidden and verify logic all ran:

```
force_walk=1: skipping the init bind to exercise the walk
no propagation to zygote - injecting per namespace
[debug] skipping hidden namespace mnt:[4026533432] (pid 3070)
injected into 22 namespace(s), skipped 1 hidden
verified: zygote 1266 sees 8b8cba7d.1
verified: zygote 1505 sees 8b8cba7d.1
```

Safety property confirmed by measurement afterwards:

| process | denylisted | `tmd_store` mounts | certs visible |
|---|---|---|---|
| `com.google.android.gms` | yes | 0 | 130 (pristine) |
| `com.android.settings` | no | 1 | 132 |

The hiding Shamiko applies to `gms` was left intact.

Note: in this debug mode the staged set contains a duplicate
(`8b8cba7d.0` from the module mount plus `8b8cba7d.1` from late staging),
because the base store already includes the module's own certs. That is an
artifact of pointing the late path at `/system`; it does not occur on the real
API 34+ path, where the base is the apex store.

## Three bugs this testing found

1. **`pidof zygote` also matches USAP pool members.** Unspecialised app
   processes keep the name `zygote`/`zygote64` until they specialise, so the
   zygote list contained processes that were about to *become* apps — one of
   which specialised into `gms.persistent` between injection and verification,
   producing a spurious `VERIFY FAILED`. A real zygote is a direct child of
   init, so the list is now filtered on `PPid == 1`. Five "zygotes" became the
   correct two.
2. **`verify_late` accepted any one zygote.** It now requires every zygote, and
   warns when the count found is below what `ro.zygote` implies — the
   starved-secondary-zygote failure mode this module exists to avoid.
3. **The staging tmpfs leaked into every process.** `/dev/.tmd_store` was
   inherited device-wide, including by hidden apps, adding a mount entry named
   after the module in every app's mount table. The bind mounts keep the tmpfs
   alive on their own, so the staging path is now detached once the binds exist.
   Verified: `tmd_store` mounts are 0 globally and 0 in `gms`.

Also fixed: `touch -r` was referencing the store *directory*, whose own mtime is
set at mount time and is just as clock-skewed, so certs were still stamped 1970.
It now copies the timestamp from an existing certificate file, giving
`2009-01-01 05:30` to match the system store.

## Final device state

Test CA removed, config removed, key material destroyed. Live store back to 130,
user store empty, zero `tmd_store` mounts, module reports
`Idle - no user certificates installed.` The module itself is left installed.

---

# End-to-end TLS verification — Burp Suite, 2026-10-07

The outstanding gap from every section above: proof that the certificates are
actually *trusted* for TLS, not merely present in the store.

## Setup

Burp Suite listening on `0.0.0.0:8085`, phone proxied to it over WiFi. The
measurement oracle is Android's own **NetworkMonitor**, which probes
`https://www.google.com/generate_204` on every network change using the platform
TLS stack (conscrypt). It needs no UI interaction, is not on the DenyList, and is
not in any Xposed module's scope — and it logs the validation result verbatim.

### Confounders checked first

`zygisk-ssl-unpinning` was already disabled. The Xposed framework present is
Vector; its module database was read with sqlite:

| module | state | scope |
|---|---|---|
| `com.simo.ssl.killer` | enabled | `com.shaya.android`, `com.titancompany.tanishqapp`, `system` |
| `com.gauravssnl.bypassrootcheck.pro` | enabled | `com.titancompany.tanishqapp`, `system` |
| `mobi.acpm.sslunpinning` | enabled | `com.shaya.android` |
| `hk.kirk.trustme` | disabled | — |

Only two third-party targets are unpinned, neither of which is NetworkMonitor,
so the oracle is clean. The baseline failure below confirms it empirically: an
unpinned path would have succeeded regardless of the trust store.

## A stale anchor with a colliding subject — the renumbering feature, for real

`/system/etc/security/cacerts/9a5ba575.0` already existed, flashed via recovery
in May. **Every Burp installation issues its CA with an identical subject DN**
(`CN=PortSwigger CA, OU=PortSwigger CA, O=PortSwigger, …`), so every Burp CA
hashes to `9a5ba575` regardless of key:

| | notBefore | SHA-256 |
|---|---|---|
| `.0` — flashed via recovery, May | Mar 10 2014 | `93:F9:C9:CE:…` |
| `.1` — staged by this module | Oct 6 2014 | `94:CC:2F:D4:…` |
| live Burp CA | — | `94:CC:2F:D4:…` |

Same subject, **different key**: Burp had regenerated its CA. The flashed cert
was a dead anchor, which is why interception still failed with it installed.

This is the collision case the renumbering logic exists for. Staging user certs
and then copying the system store over them — the obvious implementation — lets
the stale `.0` win and discards the correct CA, so interception keeps failing
with no diagnostic anywhere. Keeping both as `.0` and `.1` works because Android
resolves a subject hash by trying each suffix in turn.

Note that a grep for `portswigger` across the store finds nothing when the file
is PEM-only with no appended text dump — the subject is inside the base64.
Match on the subject hash, or parse each file, instead.

## The controlled test

The stale `/system` cert cannot be deleted: `ro.boot.veritymode=enforcing` and
`/system` is 97% full, so remounting it rw risks a verity mismatch and a
bootloop. Instead it was **neutralised** through `cacerts-removed` — the same
mechanism Settings uses to disable a system CA — with a byte-identical copy, in
*both* runs, so it contributes nothing either way.

| | module | `cacerts-added` | stale May CA | result |
|---|---|---|---|---|
| **Run A** | **disabled** | empty | neutralised | `SSLHandshakeException: CertPathValidatorException: Trust anchor for certification path not found` ×4 |
| **Run B** | **enabled** | Burp CA | neutralised | `PROBE_HTTPS … time=600ms ret=204` ×2 |

Run B's log:

```
renumbered 9a5ba575.0 -> 9a5ba575.1 (subject hash collision)
staged 9a5ba575.1
Module mount active: 1 cert(s) in /system/etc/security/cacerts
```

`X-Android-Selected-Protocol=[http/1.1]` on the successful probe confirms the
connection went through the proxy rather than bypassing it.

The only variable between the runs is the module. **This is end-to-end proof
that the module makes a user-installed CA trusted by the platform TLS stack.**

## Negative control

Measured under live interception, with the module active:

| process | denylisted | certs visible | Burp CA |
|---|---|---|---|
| `com.google.android.gms` | yes | 130 | **absent** |
| `com.google.android.gms.persistent` | yes | 130 | **absent** |
| `com.android.systemui` | no | 131 | present |
| `com.android.chrome` (after removal from the DenyList) | no | 131 | present |

The app-level *handshake* failure in a denylisted app was not directly captured —
`gms` logged no handshake error in the sampled window, and several third-party
apps on this ROM resolve a launcher activity via `cmd package` yet fail to start
via `am`. The loss of the certificate in denylisted namespaces is measured; the
resulting handshake failure is inferred from that plus Run A.

---

# Suffix sequences must be contiguous

Found by accident while cleaning up the stale CA, and it is the most important
constraint in this whole document.

After the dead `9a5ba575.0` was deleted from the system partition, an experiment
left the module's certificate staged at `9a5ba575.1` with **nothing at `.0`**.
Trust failed:

```
cacerts-removed: 0 files
store has: /system/etc/security/cacerts/9a5ba575.1
PROBE_HTTPS ... SSLHandshakeException: Trust anchor for certification path not found
```

The certificate was present, correctly labelled, and the only PortSwigger
anchor on the device — and still invisible. **Android resolves a subject hash by
trying `<hash>.0`, `.1`, `.2` … and stops at the first index that does not
exist.** A gap orphans everything above it, with no error logged anywhere.

Consequences for the staging logic:

- The search for a free suffix must **always start at 0**, never at whatever
  suffix the source file in `cacerts-added` happens to carry. A user cert named
  `<hash>.3` staged verbatim would never be found.
- A slot must never be *skipped*, for any reason - including one blocked by a
  disabled-CA alias (below). Skipping produces exactly the orphaned `.1` above.
- Anyone removing a certificate from the system partition by hand must not leave
  a gap either. Deleting `.0` while `.1` exists hides both.

Verified after the fix: `staged 9a5ba575.0`, `PROBE_HTTPS ... ret=204`.

## `cacerts-removed` matches by alias, not by content

Disabling a system CA in Settings records its **filename** under
`/data/misc/user/<id>/cacerts-removed/`. The platform then suppresses that slot
by name, regardless of what the file at that path now contains. Measured
directly:

```
/system/etc/security/cacerts/9a5ba575.0       = 94cc2fd4...  (live, correct CA)
/data/misc/user/0/cacerts-removed/9a5ba575.0  = 419ceec3...  (old, different cert)
PROBE_HTTPS ... Trust anchor for certification path not found
```

Removing the alias restored trust immediately (`ret=204`), without a reboot —
the directory is consulted live.

Because the slot cannot be skipped without creating a gap, the module stages
into it anyway and reports the situation rather than failing silently.

## Reporting a name conflict

When a staged certificate has to be renumbered because the slot is taken, the
module records it and surfaces it in three places: the log, the module
`description` in the manager's list (`… 1 name conflict(s), press Action.`), and
the Action button, which prints what collided and how to inspect or remove the
existing certificate on the read-only system partition — including the warning
about not leaving a gap.

---

# Status reporting

## The Action button did not display on the test device

`action.sh` was wired to the manager's Action button. On the test device
(Magisk 30700) pressing it showed nothing, for any module state.

The script itself is not at fault. Two real bugs were found and fixed while
chasing this:

- `MODDIR=${0%/*}` yields `sh` when `$0` carries no slash, which happens when a
  host sources the script or runs `sh -c ". action.sh"`. The library then failed
  to load and the script aborted before printing anything:
  `.: sh/tmd.sh: No such file or directory`. All three entry scripts now fall
  back to the absolute module path.
- The per-app check took **9.55s**, spawning a `sed` and a `cat` for each of
  ~400 processes. A single `awk` pass over `/proc/[0-9]*/status` brought it to
  **1.67s**.

After both fixes the script was run in the exact environment Magisk uses —
Magisk's own busybox ash in standalone mode — and produced its full report with
exit status 0:

```
/data/adb/magisk/busybox ash -o standalone /data/adb/modules/TrustMeDarling/action.sh
  28 app(s) can see the certificates
  10 app(s) can NOT: ...
EXIT=0
```

So the remaining fault is on the display side of that Magisk build, not in the
module. Magisk's own guide notes that Action support arrived in v27008 Canary
and became official in v28.0, and that output is taken from stdout; 30700 is
well beyond both. Unresolved, and not worth more effort: the log file and the
module description line both work reliably, and running the script directly
always works.

## WebUI: built, then removed

A read-only WebUI (`webroot/`, neoPOP styling, rendering `action.sh` output) was
built and its parser verified against the device's real output. It was dropped once the Action button could not be made to display either,
leaving no way to confirm the page rendered on the target device.
MMRL is installed there but its main activity does not start via `am`.

Should it ever be revisited: a WebUI needs only `webroot/index.html` plus the
host's `ksu.exec` bridge. Native on KernelSU and APatch; on Magisk it needs
MMRL / WebUI X or KsuWebUI. A localhost HTTP server is not required and would be
strictly worse — a long-lived process and a port for no benefit.
