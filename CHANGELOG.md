## v2.1

Scoped to certificates, and hardened against what three Android versions on
real hardware actually did.

* **Fixed a race that left apps untrusted.** The per-namespace walk enumerated
  the whole process table before binding anything, so on a device with Google
  services — where that enumeration takes tens of seconds — every app forked
  during the window inherited an unpatched namespace and was never revisited.
  Measured on Android 15: 9 of 54 apps could not see the certificates. Zygotes
  are now bound first, before any enumeration, so anything forked afterwards
  inherits the mount. Same device, same build, after the fix: 54 of 54.
* Verified end-to-end with live proxy interception on **Android 13**
  (`/system` store, `user` build), **Android 14** and **Android 15** (conscrypt
  APEX, real updatable APEX, with Google services present).
* Removed everything that was not about certificates: the module no longer
  reads Magisk's DenyList database or any root-hiding tool's configuration. It
  still reports which apps can and cannot see the certificates, because that is
  a measurement of the certificates themselves.
* The status line now distinguishes success from failure instead of always
  reading "Active".

## v2.0

* Reports which apps will **not** see your certificates. Root-hiding layers
  (Shamiko, Magisk DenyList, KernelSU's umount) revert module mounts inside the
  apps they hide, so a certificate module can work perfectly and still look
  broken. Shown at boot in the log, in the one-line module description, and by
  `action.sh`.
* Suffix allocation is contiguous from `.0`. Android resolves a subject hash by
  trying `.0`, `.1`, `.2` ... and stops at the first missing index, so a gap
  makes every certificate above it invisible with no error anywhere.
* A user certificate whose subject hash collides with an existing one is
  renumbered instead of overwriting it. Two CAs with the same subject but
  different keys — two Burp installations, for instance — now both work.
* Only user certificates are staged. Directory contents are merged by the root
  manager, so copying the system store in as well was unnecessary and renamed
  files that `cacerts-removed` matches by name.
* Android 14+ support for the conscrypt APEX trust store: mounts into init's
  namespace, then checks whether zygote already sees it and only walks
  namespaces when propagation did not do the job. Namespaces scrubbed by a
  hiding layer are skipped rather than re-mounted, so hiding you asked for is
  not undone. Verified on Android 14 with real proxy interception.
* Verifies its own work and fails loudly. Every zygote must see the certificate,
  and a secondary zygote on a mixed-ABI device is not allowed to be missed.
* Inert when no user certificates are installed: no `system/` directory is
  created, so the module contributes no mounts at all.
* Tool resolution falls back to the root manager's busybox when the platform
  toybox lacks `nsenter`, `pidof` or `pgrep`.
* Requires Android 11 (API 30) or newer. Pure shell, no compiled code, so it is
  architecture-agnostic.
