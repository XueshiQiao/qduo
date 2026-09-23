---
name: release
description: Cut a new QDuo release end to end — write the bilingual release notes, run bump-version.sh, watch CI, verify the downloaded DMG launches signed and notarized, confirm the Homebrew cask moved.
disable-model-invocation: true
---

# Release QDuo

Adapted from AnyDrag's release skill; the pipeline is the same family. Each phase is a
checkpoint — say what you are about to do, then do it. Releasing is gated: only run this
when the user has said to release.

## Phase 0 — Check the state

1. `git status` — stop if there are uncommitted changes that are not yours to ship.
2. `git fetch origin && git log --oneline origin/main..main` and `main..origin/main` — know
   what is local-only and what is behind.
3. `gh issue list --repo XueshiQiao/qduo --state open` — note issues this release closes.

## Phase 1 — Prepend this version's notes to `RELEASE_NOTES.html`

The version is `YY.MM.<build>`: local year and month, and `CURRENT_PROJECT_VERSION` in
`project.yml` + 1. The file is cumulative — add a new block at the TOP, English first:

```html
<h3>What's New in YY.MM.<build></h3>
<ul>
  <li><b>Feature</b> — plain description, at most two sentences.</li>
</ul>

<h3>YY.MM.<build> 更新内容</h3>
<ul>
  <li><b>功能</b> — 中文直接写，不要逐字翻译。</li>
</ul>
```

- Both headings must keep exactly this shape: CI cuts the English block out of the file by
  `<h3>What's New in <version></h3>` for the GitHub Release body, and the whole file goes
  into Sparkle's update dialog.
- Credit contributors with a bare `@handle` (not wrapped in `<a>`), so GitHub adds them to
  the release's Contributors list. `#N` references may stay links.
- Follow the `release-notes-style` skill for wording.
- Leave the file uncommitted — Phase 2 folds it into the release commit.

## Phase 2 — `scripts/bump-version.sh` (no `--push`)

It refuses a dirty tree (other than `RELEASE_NOTES.html`), rebases onto `origin/main`,
bumps `MARKETING_VERSION` + `CURRENT_PROJECT_VERSION`, commits `chore(release): <version>`
and tags `v<version>`. It warns if the notes have no block for the new version — fix that
before going on.

## Phase 3 — Check, then push

```bash
git show --stat HEAD
[ "$(git rev-parse v<version>)" = "$(git rev-parse HEAD)" ] || echo "TAG MISMATCH — DO NOT PUSH"
git push origin main && git push origin v<version>
```

The tag push starts `.github/workflows/build.yml`: tests → universal build → sign (with the
embedded Developer ID provisioning profile) → notarize → staple → Gatekeeper check → DMG →
Sparkle EdDSA signature → `appcast.xml` + `latest.json` → GitHub Release → Homebrew dispatch.

## Phase 4 — Watch CI

```bash
RUN=$(gh run list --repo XueshiQiao/qduo --workflow build.yml --limit 5 \
  --json databaseId,headBranch --jq '.[] | select(.headBranch=="v<version>") | .databaseId' | head -1)
gh run watch "$RUN" --repo XueshiQiao/qduo --exit-status
```

A failed run publishes nothing. The Sign App step fails on purpose if the provisioning
profile is missing, belongs to another app, has expired, or does not authorise the
certificate in the `.p12` — each of those would otherwise ship an app the system kills at
launch while every static check passes (see XTools `docs/developer-id-keychain-amfi-postmortem.html`).

## Phase 5 — Verify the download, the way a user gets it

CI being green is not the test. Download the published DMG, mark it as downloaded by a
browser, and launch it:

```bash
cd "$(mktemp -d)"
gh release download v<version> --repo XueshiQiao/qduo --pattern QDuo.dmg
xattr -w com.apple.quarantine "0081;$(printf %x $(date +%s));Safari;" QDuo.dmg
hdiutil attach -nobrowse -mountpoint ./mnt QDuo.dmg
spctl -a -t exec -vv ./mnt/QDuo.app          # → source=Notarized Developer ID
xcrun stapler validate ./mnt/QDuo.app
codesign -d --entitlements - ./mnt/QDuo.app  # → 584KQTRF3B.me.xueshi.qduo.keychain
open ./mnt/QDuo.app; sleep 4; pgrep -x QDuo && echo LAUNCHED
log show --last 1m --predicate 'process == "amfid"' | grep -i qduo   # should be empty
```

Quit it afterwards and `hdiutil detach ./mnt`. If it did not launch, stop — do not
announce the release.

Also check the update feed resolves:
`curl -sL https://github.com/XueshiQiao/qduo/releases/latest/download/appcast.xml | grep shortVersionString`.

## Phase 6 — Homebrew cask

The release run dispatches to `XueshiQiao/homebrew-tap`, which regenerates `Casks/qduo.rb`
from `latest.json`:

```bash
gh run list --repo XueshiQiao/homebrew-tap --workflow update-casks.yml --limit 1
gh api repos/XueshiQiao/homebrew-tap/contents/Casks/qduo.rb --jq .content | base64 -d | head -5
```

Re-fire by hand if needed: `gh workflow run update-casks.yml --repo XueshiQiao/homebrew-tap -f app_token=qduo`.

## Phase 7 — Close issues, report

Close each issue from Phase 0 with a comment that links the release and @mentions the
reporter (the release body credits them but does not reliably notify). Then report: release
URL, CI run URL, the Phase 5 results, the tap run, issues closed.

## Secrets this relies on (repository secrets)

`MAC_CERTS_P12_BASE64`, `MAC_CERTS_P12_PASSWORD` (Developer ID Application certificate),
`APPLE_ID`, `APPLE_TEAM_ID`, `APP_SPECIFIC_PASSWORD` (notarization), `MAC_PROVISION_PROFILE_BASE64`
(the QDuo Developer ID profile, app id `me.xueshi.qduo`, expires 2044), `SPARKLE_EDDSA_KEY`
(keychain account `qduo`), `HOMEBREW_TAP_PAT`. The first five and the PAT are shared with
XTools; the profile and the Sparkle key belong to QDuo alone. If the Developer ID certificate
is ever renewed, the profile must be regenerated against the new one — CI will say so.
