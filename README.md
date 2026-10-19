# GCP V3 guided setup source

This directory is the reviewed source package for the V3 Connection-v2 GCP
Cloud Shell artifact. It is not a live artifact and must not be linked from the
backend while nested in this private repository.

The cloud architect publishes these files at the root of the dedicated public
repository named in `artifact-config.json`. A release is valid only when:

1. The dedicated repository contains exactly the reviewed runtime package.
2. Its commit is GitHub Verified.
3. A protected branch named `release-<40-character commit SHA>` points to that
   commit and cannot be updated, deleted, or force-pushed under the repository
   ruleset. GitHub prohibits a bare 40-hex ref name.
4. `artifactVersion` is that commit SHA.
5. `artifactDigest` is the digest printed by `lib/integrity.sh` for the reviewed
   manifest.
6. The backend Cloud Shell URL uses only `cloudshell_git_repo`,
   `cloudshell_git_branch`, `cloudshell_tutorial`, `cloudshell_workspace`,
   `ephemeral`, and `show`, with the branch equal to
   `release-<artifactVersion>`.
7. Ersin approves the backend contract and Chavdar approves every GCP command,
   permission, release control, and disposable-project proof.

No release, Helm value, cloud resource, deployment, or live proof is performed
by adding this source package.

Local verification:

```bash
bash -n setup.sh lib/*.sh tests/run.sh tests/test-support.sh tests/mocks/*
shellcheck -x -P . -P tests setup.sh tests/run.sh tests/mocks/*
./print-artifact-digest.sh
tests/run.sh
```

The older draft files directly under `deploy/gcp/` predate Connection-v2 and
contain superseded wildcard/Token Creator examples. They are not authority for
this artifact.
