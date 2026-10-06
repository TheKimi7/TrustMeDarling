# Trust Me Darling!

Makes user-installed CA certificates part of the Android system trust store —
and tells you which apps will not see them.

## Why the second half matters

Root-hiding layers (Shamiko, Magisk's DenyList, KernelSU's umount) revert module
mounts inside the apps they hide. A certificate module can be working perfectly
and still appear completely broken, because the app you are testing is on a
denylist. There is no error anywhere; the certificate is simply absent.

This module reports that instead of leaving you to guess. At boot it names the
affected packages in its log, and the Action button checks every running app by
entering its mount namespace and looking.

## Install

Android 11 (API 30) or newer. Build the zip from a checkout:

```sh
zip -r TrustMeDarling.zip . -x '.git/*' -x 'docs/*' -x '*.zip'
```

Flash it in Magisk, then reboot. Add a CA under **Settings → Security →
Encryption & credentials → Install a certificate → CA certificate**, then reboot
again. Android requires a screen lock for that flow; without one, place the
certificate in `/data/misc/user/0/cacerts-added/<subject_hash_old>.0` instead
(owner `system:system`, mode `644`).

Magisk is the only manager tested so far. KernelSU and APatch use the same
module interface and should work, but are unverified.

No compiled code, so it is architecture-agnostic: arm64, arm32, x86_64 and
riscv64 are all the same shell.

## How it works

| Android | Trust store | Mechanism |
|---|---|---|
| 11 – 13 | `/system/etc/security/cacerts` | User certs are staged into the module tree during `post-fs-data`, before modules are mounted, so the root manager's own merge publishes them. No mounting here. |
| 14+ | `/apex/com.android.conscrypt/cacerts` | The module tree cannot reach a path inside an APEX, so `service.sh` builds a merged store in its own tmpfs and binds it over the apex directory after boot. |

Which store is live is decided at runtime — the apex directory must exist *and*
the API level must be 34+, mirroring conscrypt's own gate — so a preview build or
an unknown future version degrades to a clear failure rather than a silent one.

On the 14+ path the module binds into init's namespace first and then checks
whether zygote can already see it. Where the mount propagates, nothing further
happens. Only when it does not does the module walk zygote's descendants, and it
skips any namespace that has been scrubbed by a hiding layer rather than
re-mounting there and undoing hiding you asked for.

## Status

Everything the module decided is reported in two places, both read-only:

- **`/data/adb/TrustMeDarling/log.txt`** — what was staged, any renaming, which
  apps will not see the certificates and why.
- **The one-line summary** under the module name in the manager's list, e.g.
  `Active - 1 cert(s); 9 app(s) hidden.`

`action.sh` prints a fuller report, including a per-app visibility check, and is
wired to the manager's Action button. On Magisk the Action button did not
display its output on the test device; running it directly always works:

```sh
su -c 'sh /data/adb/modules/TrustMeDarling/action.sh'
```

## Status

- Android 11–13 path: **verified on hardware** (Redmi 6 Pro, Android 13, Magisk
  30.7), including **end-to-end TLS interception through Burp Suite**. See
  [docs/device-testing.md](docs/device-testing.md).
- Android 14+ path: **implemented, not yet verified** — no test device. Reports
  welcome.

## Notes

- Certificates are re-staged every boot, so adding or removing one needs a
  reboot. The root manager copies module-added files into its mount skeleton, so
  deleting one does not take effect until then either.
- On the 14+ path the mounts are not re-applied if zygote restarts after boot.
  A zygote restart kills every app anyway; reboot if certificates stop working.
- A user cert whose subject hash collides with a system cert is renumbered to
  the next free suffix instead of overwriting it. Suffixes are allocated
  contiguously from `.0`, because Android stops scanning a subject hash at the
  first missing index — a gap makes every certificate above it invisible.
- Name conflicts are reported in the log, in the module description, and by the
  Action button, which also explains how to remove a stale system certificate.
- Log: `/data/adb/TrustMeDarling/log.txt`. Set `debug=1` in
  `/data/adb/TrustMeDarling/config` for more.

## Licence

Copyright (C) 2026 TheKimi7

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See [LICENSE](LICENSE).
