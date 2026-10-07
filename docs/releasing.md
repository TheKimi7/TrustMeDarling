# Cutting a release

A release is three things that must agree, because the manager polls the
`updateJson` URL in `module.prop` and compares its `versionCode` with the
installed one.

1. `module.prop`, holding `version` and `versionCode`.
2. `update.json`, holding the same two plus a `zipUrl` that exists.
3. A GitHub release tagged `<version>` with that zip attached.

`tools/release.sh` generates `update.json` from `module.prop`. Never edit it by
hand, because that is how the two version numbers drift apart, and drift is the
usual reason an update prompt never appears.

## Bump the version in module.prop only

```
version=v2.1
versionCode=2100
```

`versionCode` must be an integer and must increase. It is the only value the
manager compares, so a new `version` string with an unchanged code produces no
prompt. The convention here is `v2.1` for the string and `2100` for the code.

## Write the changelog

Add a section at the top of `CHANGELOG.md`. The manager fetches it raw, so it
has to read well as plain text.

## Commit before building

```sh
git add -A && git commit -m "v2.1"
```

The script refuses to publish from a dirty tree.

## Build and check locally

```sh
tools/release.sh
```

This writes `dist/TrustMeDarling-v2.1.zip` and regenerates `update.json`. It
then verifies the zip contains the installer and the scripts, and none of
`docs/`, `tools/` or `update.json`. Nothing is pushed.

## Test the artifact, not the working tree

```sh
adb push dist/TrustMeDarling-v2.1.zip /data/local/tmp/rel.zip
adb shell su -c 'magisk --install-module /data/local/tmp/rel.zip'
adb reboot
# then: adb shell su -c 'cat /data/adb/TrustMeDarling/log.txt'
```

Do not pipe the installer's output through `head` or similar. The early pipe
close sends SIGPIPE and kills the install part way, which looks like a module
fault and is not one.

## Publish

```sh
git add update.json && git commit -m "update.json for v2.1"
tools/release.sh --publish
```

That tags the commit, pushes `main` and the tag, and creates the release with
the zip attached. The equivalent by hand:

```sh
git tag -a v2.1 -m v2.1 && git push origin main --tags
gh release create v2.1 dist/TrustMeDarling-v2.1.zip --notes-file CHANGELOG.md
```

## Verify what users will fetch

`update.json` is served from the branch, so push it only after the release
exists. Otherwise the first person to check gets a 404 for the zip.

```sh
curl -s https://raw.githubusercontent.com/TheKimi7/TrustMeDarling/main/update.json
curl -sIL -o /dev/null -w '%{http_code}\n' \
  "$(curl -s https://raw.githubusercontent.com/TheKimi7/TrustMeDarling/main/update.json | sed -n 's/.*"zipUrl": "\([^"]*\)".*/\1/p')"
```

Expect the new `versionCode` and `200` for the zip. Downloading the published
zip and comparing its SHA-256 against `dist/` confirms the asset is the one you
built.

## Notes

- The repository must stay public. If it is private, `raw.githubusercontent.com`
  returns 404 and nobody is ever offered an update.
- The update check is the manager fetching your GitHub URL on refresh, which
  tells GitHub that a device has this module installed, along with an IP. That
  is normal for Magisk modules. It is worth knowing anyway, because many users
  of this module run Shamiko and Play Integrity Fix to avoid exactly that kind
  of signal. Deleting the `updateJson` line disables the check and breaks
  nothing else.
- `zipUrl` must point at a release asset rather than a repository archive. A
  GitHub source tarball has a wrapping directory and will not install.
