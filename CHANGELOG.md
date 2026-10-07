## v2.1

Scoped back to certificates, and corrected against what three Android versions
did on real hardware.

* **Fixed a race that left apps untrusted.** The per-namespace walk enumerated
  the whole process table before binding anything. On a device with Google
  services that enumeration takes about fifty seconds, so every app forked
  during the window inherited an unpatched namespace and was never revisited.
  Measured on Android 15, 9 of 54 running apps could not see the certificates.
  Zygotes are now bound first, before any enumeration, so anything forked
  afterwards inherits the mount. The same device on the same build then reported
  54 of 54.
* Verified end to end with live proxy interception on Android 13, Android 14 and
  Android 15. The Android 13 device ran a `user` build with `ro.debuggable=0`
  and used the `/system` store. The Android 14 and 15 devices used a real
  updatable Conscrypt APEX, and the Android 15 one had Google services
  installed.
* Removed everything that was not about certificates. The module no longer reads
  Magisk's DenyList database or any root-hiding tool's configuration. It still
  reports which apps can and cannot see the certificates, because that is a
  measurement of the certificates themselves.
* The one-line status now distinguishes success from failure. Earlier versions
  always read "Active", including when no mount had succeeded.

## v2.0

* Reports which apps will not see your certificates. Shamiko, Magisk's DenyList
  and KernelSU's umount revert module mounts inside the apps they hide, so a
  certificate module can work perfectly and still appear broken. The report
  appears in the boot log, in the module description and in `action.sh`.
* Suffixes are allocated contiguously from `.0`. Android resolves a subject hash
  by trying `.0`, `.1`, `.2` and so on, stopping at the first missing index, so a
  gap makes every certificate above it invisible with no error anywhere.
* A user certificate whose subject hash collides with an existing one is
  renumbered rather than overwriting it. Two CAs that share a subject but differ
  in key, such as two Burp installations, now both work.
* Only user certificates are staged. Root managers merge directory contents, so
  copying the system store in as well added nothing and renamed files that
  `cacerts-removed` matches by name.
* Added support for the Conscrypt APEX trust store on Android 14 and newer. The
  module mounts into init's namespace, then checks whether zygote already sees
  it, and walks namespaces only when propagation did not do the job. Namespaces
  whose mounts were reverted by root-hiding are skipped rather than re-mounted,
  so hiding that was asked for stays in place.
* Verifies its own work and fails loudly. Every zygote must see the certificate,
  and a secondary zygote on a mixed-ABI device is not allowed to be missed.
* Creates nothing when no user certificates are installed. Without a `system/`
  directory the module contributes no mounts at all.
* Falls back to the root manager's busybox when the platform toybox lacks
  `nsenter`, `pidof` or `pgrep`.
* Requires Android 11 (API 30) or newer. It is pure shell with no compiled code,
  so it runs on any architecture.
