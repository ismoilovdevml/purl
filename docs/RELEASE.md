# Release process

Purl publishes two artifacts that must stay in lockstep:

| Artifact     | Where                                            | Version field              |
|--------------|--------------------------------------------------|----------------------------|
| Docker image | `ismoilovdev/purl`                               | git tag `vX.Y.Z`           |
| Helm chart   | <https://charts.purlogs.com> (`purl-N.N.N.tgz`)  | `chart/Chart.yaml` `version` |

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

# 5. Publish the chart (manual, not wired into CI).
make chart-publish

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
* **Chart**: `charts.purlogs.com` keeps every published `.tgz`, so
  `helm upgrade purl purl/purl --version <previous>` is always available.
* **Dev cluster**: `ssh root@5.189.148.112 'helm -n purl-dev rollback purl <rev>'`

## Base images

`Dockerfile` pins base images by digest, not tag, so a rebuild produces the
image CI scanned. Refresh them deliberately:

```bash
docker buildx imagetools inspect perl:5.40-slim-bookworm   # copy index Digest
docker buildx imagetools inspect node:20-alpine
```
