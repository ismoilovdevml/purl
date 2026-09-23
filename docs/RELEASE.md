# Release process

Purl publishes two artifacts that must stay in lockstep:

| Artifact     | Where                                            | Version field              |
|--------------|--------------------------------------------------|----------------------------|
| Docker image | `ismoilovdev/purl`                               | git tag `vX.Y.Z`           |
| Helm chart   | <https://ismoilovdevml.github.io/purl> (GitHub Release `purl-N.N.N`) | `chart/Chart.yaml` `version` |

The chart resolves the image tag from `Chart.yaml` **`appVersion`** — `image.tag`
defaults to `""` and falls back to it. So:

> `appVersion` must always name a Docker tag that actually exists.

If it does not, every public `helm install purl/purl` ends in `ImagePullBackOff`.
CI enforces this: the **Release Tag Guard** job fails a `v*` tag push whose
version does not equal `chart/Chart.yaml` `appVersion`, and also fails if the
tag is not reachable from `main`.

## What CI publishes

| Trigger                | Docker tags produced                          |
|------------------------|-----------------------------------------------|
| push to `main`         | `latest`, `<sha>`                             |
| push to `dev`          | `dev`, `<sha>` (+ auto-deploy to `purl-dev`)  |
| push tag `vX.Y.Z`      | `X.Y.Z`, `X.Y`, `<sha>`                       |

The Helm chart is published by `.github/workflows/chart-release.yml`:

| Trigger                                         | What happens                                        |
|-------------------------------------------------|-----------------------------------------------------|
| push to `main` changing `chart/Chart.yaml`      | publishes the chart **if** `ismoilovdev/purl:<appVersion>` exists |
| CI/CD run for a `vX.Y.Z` tag finishes green     | same check again — this is where a release publishes |
| `gh workflow run chart-release.yml`             | same, by hand (re-run after a failure)              |

Publishing = GitHub Release `purl-<version>` with the `.tgz` as its asset, plus
an entry in `index.yaml` on the `gh-pages` branch (served by GitHub Pages).
A version already in that index is never republished, so every extra run is a
no-op. A chart whose `appVersion` image is not on Docker Hub yet is **held
back with a warning**, not published — that is why a release commit's chart
ships after its tag build, not on the main push.

Tag pushes deliberately do **not** move `latest` — a `git tag` is not
branch-constrained, so tagging an unmerged commit would otherwise republish
production `:latest`.

Every published image is scanned by Trivy (fails on fixable HIGH/CRITICAL),
signed with cosign (keyless/OIDC) and has an SPDX SBOM attested to its digest.

## Cutting a release

```bash
# 1. On main, with the release commit merged.
git checkout main && git pull

# 2. Bump BOTH versions in chart/Chart.yaml:
#      version:    <chart version, bump on any chart change>
#      appVersion: "X.Y.Z"   <- the app/image version being released
$EDITOR chart/Chart.yaml
git commit -am "chore(release): v X.Y.Z" && git push

# 3. Gate: verifies appVersion == VERSION, clean tree, on main,
#    then runs preflight + helm-lint. Prints the tag commands.
make release VERSION=X.Y.Z

# 4. Tag and push — CI builds, scans, signs and publishes the semver tags.
git tag -a vX.Y.Z -m "Purl vX.Y.Z"
git push origin vX.Y.Z

# 5. Nothing to do for the chart: when the tag's CI/CD run is green, the
#    Chart Release workflow publishes chart/Chart.yaml's version.
gh run list --workflow chart-release.yml --limit 3

# 6. Verify.
docker manifest inspect ismoilovdev/purl:X.Y.Z >/dev/null && echo "image ok"
helm repo update && helm search repo purl/purl --versions | head
```

## Verifying a published image

```bash
cosign verify \
  --certificate-identity-regexp '^https://github.com/ismoilovdevml/purl/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ismoilovdev/purl:X.Y.Z
```

## Rollback

* **Image**: republish nothing — point installs at the previous semver tag
  (`--set image.tag=X.Y.Z-1`), or revert `appVersion` and cut a new chart
  version.
* **Chart**: every published version stays in the GitHub Pages index and as a
  GitHub Release, so `helm upgrade purl purl/purl --version <previous>` is
  always available. To withdraw a bad version, remove its entry from
  `index.yaml` on `gh-pages` (keep the Release for the audit trail) and
  publish a fixed chart version — never re-publish the same version.
* **Dev cluster**: `ssh root@5.189.148.112 'helm -n purl-dev rollback purl <rev>'`

## Base images

`Dockerfile` pins base images by digest, not tag, so a rebuild produces the
image CI scanned. Refresh them deliberately:

```bash
docker buildx imagetools inspect perl:5.42-slim-bookworm   # copy index Digest
docker buildx imagetools inspect node:24-alpine
```

Only **stable** bases: Perl even minors (5.42, 5.44, ...) — odd minors are
development releases — and Node LTS majors. Dependabot ignores odd Perl minors
and odd Node majors (`.github/dependabot.yml`); an even Node major is still
"Current" for its first ~6 months, so check it is LTS before merging.

## One-time GitHub Pages setup

Needed once, before the first Chart Release run. The workflow fails with
"Branch gh-pages does not exist" until it is done.

It also imports the chart versions published on the old Vercel repo
(`charts.purlogs.com`: 1.0.0, 1.0.1, 1.0.2). `chart-releaser` builds on
whatever `index.yaml` is on `gh-pages` and only adds entries, so seeding that
file with the old entries — re-pointed at GitHub Release assets carrying the
byte-identical `.tgz` files, so the digests stay valid — keeps them
installable after Vercel is retired.

```bash
set -euo pipefail
REPO=ismoilovdevml/purl
WORK=$(mktemp -d) && cd "$WORK"

# 1. Download the published packages and check them against the live index.
curl -fsSLO https://charts.purlogs.com/index.yaml
for v in 1.0.0 1.0.1 1.0.2; do
  curl -fsSLO "https://charts.purlogs.com/purl-$v.tgz"
  want=$(yq ".entries.purl[] | select(.version == \"$v\") | .digest" index.yaml)
  have=$(shasum -a 256 "purl-$v.tgz" | cut -d' ' -f1)
  [ "$want" = "$have" ] || { echo "digest mismatch for $v"; exit 1; }
done

# 2. One GitHub Release per old version, in chart-releaser's naming
#    (purl-<version>), not marked latest (that stays the app release).
for v in 1.0.0 1.0.1 1.0.2; do
  gh release create "purl-$v" "purl-$v.tgz" -R "$REPO" --latest=false \
    --target main --title "purl-$v" --notes "Helm chart $v (imported from charts.purlogs.com)"
done

# 3. Seed index.yaml with the old entries re-pointed at those assets.
sed -E 's#https://charts\.purlogs\.com/(purl-([0-9.]+)\.tgz)#https://github.com/'"$REPO"'/releases/download/purl-\2/\1#' \
  index.yaml > seed-index.yaml

# 4. Create the orphan gh-pages branch holding only index.yaml.
git clone --no-checkout "https://github.com/$REPO.git" pages && cd pages
git switch --orphan gh-pages
cp ../seed-index.yaml index.yaml
git add index.yaml && git commit -m "chore(chart): seed Helm repo index with 1.0.x releases"
git push origin gh-pages

# 5. Serve gh-pages at https://ismoilovdevml.github.io/purl
gh api -X POST "repos/$REPO/pages" -f 'source[branch]=gh-pages' -f 'source[path]=/'
```

Then check **Settings > Actions > General > Workflow permissions**: the
workflow asks for `contents: write` itself, which works under either setting
unless an organization policy caps `GITHUB_TOKEN` at read-only. After that,
`gh workflow run chart-release.yml` publishes the current chart version (if
its `appVersion` image exists) and
`helm repo add purl https://ismoilovdevml.github.io/purl` works.

`https://charts.purlogs.com` (Vercel) stays up, frozen at 1.0.2, until it is
retired; `make chart-publish-vercel` is its legacy manual path and must not be
used for new versions.
