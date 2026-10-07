<div align="center">

# TrustMeDarling!

**Your CA certificate, trusted system-wide, and a straight answer when it isn't.**

[![Version](https://img.shields.io/badge/version-v2.1-blue)](https://github.com/TheKimi7/TrustMeDarling/releases/latest)
[![Android](https://img.shields.io/badge/Android-11%20%E2%80%93%2015-green)](#android-11-and-newer-on-any-architecture)
[![Licence](https://img.shields.io/badge/licence-GPL--3.0-orange)](LICENSE)

</div>

---

## User certificates become system certificates

Install a CA the normal way, through Settings, and this module copies it into the
**system** trust store at boot. Apps that trust only system CAs then accept your
proxy.

On Android 11 to 13 the store is `/system/etc/security/cacerts`. From Android 14
it moved inside the read-only Conscrypt APEX, so the module mounts a merged store
over it after boot instead. Which one is live is detected at runtime rather than
assumed, so an unknown or preview release fails visibly instead of silently.

## Root-hiding removes the certificate from the apps it hides

Shamiko, Magisk's DenyList and KernelSU's umount all revert module mounts inside
the apps they hide. Your certificate sits in the system trust store everywhere
except the one app you are trying to intercept. Nothing logs this and no error
appears, so the proxy looks broken when it is fine.

The module checks each running app from inside that app's own mount namespace, so
it reports what is true rather than what should be true.

```
TrustMeDarling!
  android     : 35 (REL)
  manager     : Magisk 30700
  trust store : /apex/com.android.conscrypt/cacerts

Certificates added by this module (1):
  9a5ba575.0

Store: OK - 146 certificates in /apex/com.android.conscrypt/cacerts

Per-app check - trusted, measured per running app:
  51 app(s) trust the certificates
```

When apps come up short they are named, and the report points at root-hiding as
the usual cause.

## Installation needs two reboots

1. Download the latest zip from [Releases](https://github.com/TheKimi7/TrustMeDarling/releases/latest).
2. Flash it in Magisk, KernelSU or APatch, then reboot.
3. Add your CA under **Settings → Security → Encryption & credentials → Install a certificate → CA certificate**.
4. Reboot again, because certificates are staged at boot.

Android requires a screen lock before it will install a CA through Settings. If
you do not use one, put the certificate at
`/data/misc/user/0/cacerts-added/<subject_hash_old>.0` instead, owned
`system:system` with mode `644`.

## The log says whether the certificates are trusted

```sh
su -c 'cat /data/adb/TrustMeDarling/log.txt'
```

The module also rewrites its own one-line description in your manager's module
list, so the state is visible without opening anything.

```
Active - 1 cert(s) in the conscrypt APEX store.
Active - 2 cert(s) in the system store. 1 renamed on collision.
FAILED - certificates are not trusted. See the log.
Idle - no user certificates installed.
```

The full per-app report comes from the Action button, or directly:

```sh
su -c 'sh /data/adb/modules/TrustMeDarling/action.sh'
```

## Four things explain almost every failure

**The app you are testing is hidden from root.** This is by far the most common
cause. Run the per-app report, which names the affected packages. Exempt that one
app from your DenyList and force-stop it.

**Your proxy's CA changed.** Every Burp installation issues its CA with an
identical subject name, so an old certificate and a current one share a filename
despite having different keys. The stale one will sit there validating nothing.
Re-export from your proxy and compare SHA-256 fingerprints before looking
anywhere else.

**You did not reboot.** Certificates are staged during early boot, so adding or
removing one takes effect only after a restart.

**The log warns about a disabled-CA alias.** You previously disabled a system CA
whose subject hash matches your certificate. Android suppresses that slot by
filename whatever the file contains, so re-enable that CA under Settings →
Encryption & credentials → Trusted credentials.

## Android 11 and newer, on any architecture

| | |
|---|---|
| **Android** | 11 to 15 (API 30+) |
| **Root** | Magisk, KernelSU, APatch |
| **Architecture** | any, because it is pure shell with no compiled code |

Verified on hardware with live proxy interception on Android 13 (a `user` build
with `ro.debuggable=0`), Android 14 and Android 15. The Android 14 and 15 tests
ran against a real updatable Conscrypt APEX, and the Android 15 device had Google
services installed.

## Behaviour worth knowing before you rely on it

- Adding or removing a certificate takes effect on the next boot, because staging happens during early boot.
- With no user certificates installed the module creates no files and mounts nothing, so it is inert rather than idle.
- Certificates whose subject hash collides are renumbered to the next free suffix instead of overwriting, so a stale certificate cannot shadow a working one.
- Suffixes are allocated contiguously from `.0`, because Android stops scanning a subject hash at the first missing index and a gap would hide every certificate above it.
- The module never creates your `cacerts-added` directory and never writes to any partition.
- Set `debug=1` in `/data/adb/TrustMeDarling/config` for a verbose log.

## Licence

Copyright (C) 2026 TheKimi7

Free software under the GNU General Public License v3 or later. See
[LICENSE](LICENSE).
