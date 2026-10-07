<div align="center">

# TrustMeDarling!

**Your CA certificate, trusted system-wide — and a straight answer when it isn't.**

[![Version](https://img.shields.io/badge/version-v2.1-blue)](https://github.com/TheKimi7/TrustMeDarling/releases/latest)
[![Android](https://img.shields.io/badge/Android-11%20%E2%80%93%2015-green)](#compatibility)
[![Licence](https://img.shields.io/badge/licence-GPL--3.0-orange)](LICENSE)

</div>

---

## What it does

Install a CA certificate the normal way — Settings, "user" certificate — and this
module makes it part of the **system** trust store. Apps that only trust system
CAs stop refusing your proxy.

That part is table stakes. The reason this module exists is the other half.

## When your certificate doesn't show up

If you hide root with **Shamiko**, **Magisk's DenyList**, or **KernelSU's
umount**, those tools undo module mounts inside the apps they hide. Your
certificate is in the system trust store — everywhere except the app you're
trying to intercept.

Nothing warns you. No log, no error. The certificate is simply absent, and you
spend an evening debugging a proxy that was fine all along.

**This module tells you instead:**

```
Hiding: Shamiko in blacklist mode, 9 package(s) listed.
  These apps will NOT see the certificates:
    com.android.chrome
    com.android.vending
    com.google.android.gms
    ...
  Untick only the apps you are actually intercepting. Leave
  gms/vending listed if you rely on Play Integrity.
```

It also checks every running app directly, by looking from inside each app's own
mount namespace rather than guessing from config:

```
Per-app check - certificate visibility, running apps only:
  24 app(s) can see the certificates
  7 app(s) can NOT:
    com.google.android.gms
    com.android.vending
    ...
```

## Install

1. Download the latest zip from [**Releases**](https://github.com/TheKimi7/TrustMeDarling/releases/latest)
2. Flash it in Magisk (or KernelSU / APatch) and reboot
3. Add your CA under **Settings → Security → Encryption & credentials → Install a certificate → CA certificate**
4. **Reboot again** — certificates are picked up at boot

Android requires a screen lock for step 3. Without one, place the certificate at
`/data/misc/user/0/cacerts-added/<subject_hash_old>.0` instead, owned
`system:system`, mode `644`.

## Checking it worked

```sh
su -c 'cat /data/adb/TrustMeDarling/log.txt'
```

The module also writes a one-line summary under its own name in your manager's
module list:

```
Active - 1 cert(s) trusted system-wide.
Active - 1 cert(s); 9 app(s) hidden.
Idle - no user certificates installed.
```

For the full per-app report:

```sh
su -c 'sh /data/adb/modules/TrustMeDarling/action.sh'
```

## Not working? Read this first

**The app you're testing is hidden from root.** Far and away the most common
cause. Check the log — it names the affected packages. Untick that one app in
your DenyList and force-stop it.

**Your proxy's CA changed.** Burp regenerates its CA, and every Burp
installation issues one with an *identical* subject name. So an old certificate
and a new one are indistinguishable by filename despite having different keys —
and the old one will happily sit there validating nothing. Re-export the
certificate from your proxy and compare fingerprints before assuming anything
else is wrong.

**You didn't reboot.** Certificates are staged at boot. Adding or removing one
needs a restart.

**The log says `WARNING: ... is a disabled-CA alias`.** You previously disabled a
system CA that happens to share your certificate's subject hash. Android
suppresses that slot by name, so re-enable it under Settings → Encryption &
credentials → Trusted credentials.

## Compatibility

| | |
|---|---|
| **Android** | 11 – 15 (API 30+) |
| **Root** | Magisk · KernelSU · APatch |
| **Architecture** | any — pure shell, no compiled code |

Verified on hardware with real proxy interception on **Android 13** (`user`
build), **Android 14** and **Android 15**. Android 14+ uses a different trust store (inside the
read-only Conscrypt APEX) and the module handles it; which store is live is
detected at runtime, so preview and future releases degrade to a clear failure
rather than a silent one.

## Good to know

- Adding or removing a certificate takes effect on the next boot.
- With no certificates installed the module creates nothing and mounts nothing —
  it is completely inert.
- Certificates that collide on subject hash are renumbered, never overwritten,
  so a stale certificate can't shadow a working one.
- It never touches your `cacerts-added` directory, and never modifies any
  partition.
- Set `debug=1` in `/data/adb/TrustMeDarling/config` for a verbose log.

## Licence

Copyright (C) 2026 TheKimi7

Free software under the GNU General Public License v3 or later. See
[LICENSE](LICENSE).
