# Cutting a release

The manager shows an update prompt by polling the `updateJson` URL in
`module.prop` and comparing its `versionCode` with the installed one. So a
release is three things that must agree:

1. `module.prop` — `version` and `versionCode`
2. `update.json` — the same two, plus a `zipUrl` that really exists
3. a GitHub release at tag `<version>` with that zip attached

`update.json` is **generated** from `module.prop` by `tools/release.sh`. Never
hand-edit it; that is how the two numbers drift apart, which is the usual reason
an update prompt silently fails to appear.

## Steps

**1. Bump the version.** Edit `module.prop` only:

```
version=v2.1
versionCode=2100
```

`versionCode` must be an integer and must **increase**. The manager compares
only this number — a prettier `version` string with the same code shows no
prompt. The convention here is `v2.1` → `2100`.

**2. Write the changelog.** Add a section at the top of `CHANGELOG.md`. It is
served raw to the manager, so keep it readable as plain text.

**3. Commit.** The script refuses to publish from a dirty tree.

```sh
git add -A && git commit -m "v2.1"
```

**4. Build and check.**

```sh
tools/release.sh
```

This writes `dist/TrustMeDarling-v2.1.zip`, regenerates `update.json`, and
verifies the zip contains the installer and the scripts but none of `docs/`,
`tools/` or `update.json`. Nothing is pushed.

**5. Test the zip before publishing.** The artifact, not the working tree:

```sh
adb push dist/TrustMeDarling-v2.1.zip /data/local/tmp/rel.zip
adb shell su -c 'magisk --install-module /data/local/tmp/rel.zip'
adb reboot
# then: adb shell su -c 'cat /data/adb/TrustMeDarling/log.txt'
```

**6. Publish.**

```sh
git add update.json && git commit -m "update.json for v2.1"
tools/release.sh --publish
```

That tags, pushes, and creates the release with the zip attached. Or do it by
hand:

```sh
git tag -a v2.1 -m v2.1 && git push origin main --tags
gh release create v2.1 dist/TrustMeDarling-v2.1.zip --notes-file CHANGELOG.md
```

**7. Verify what users will actually fetch.** `update.json` is served from the
branch, so it must be pushed *after* the release exists, or the first person to
check gets a 404:

```sh
curl -s https://raw.githubusercontent.com/TheKimi7/TrustMeDarling/main/update.json
curl -sIL -o /dev/null -w '%{http_code}\n' \
  "$(curl -s https://raw.githubusercontent.com/TheKimi7/TrustMeDarling/main/update.json | sed -n 's/.*"zipUrl": "\([^"]*\)".*/\1/p')"
```

Expect the new `versionCode` and `200` for the zip.

## Notes

- The repository must stay public, or `raw.githubusercontent.com` returns 404
  and no one is ever offered an update.
- The prompt is the *manager* fetching your GitHub URL on refresh. It reveals
  that a device has this module installed, plus an IP, to GitHub. That is
  standard for Magisk modules, but it is worth knowing for a module whose users
  often run Shamiko and PIF specifically to avoid such signals. Removing the
  `updateJson` line disables it entirely and breaks nothing else.
- `zipUrl` must point at a release **asset**, not a repository archive. A GitHub
  source tarball has a wrapping directory and will not install.
