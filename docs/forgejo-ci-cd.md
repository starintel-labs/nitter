# Forgejo CI/CD

The StarIntel Nitter fork carries native Forgejo Actions workflows under
`.forgejo/workflows/` so CI does not depend on GitHub Actions.

## Workflows

### `ci.yml`

Runs on pull requests, pushes to `master`, and manual dispatches.

It compiles Nitter against the two supported Nim lines used by the project:

- Nim 2.0.14
- Nim 2.2.10

Each matrix job runs in the matching official Nim Alpine image, installs the
native build dependencies, checks out the exact Forgejo event ref, installs
Nimble dependencies, compiles Nitter, and renders the SCSS/Markdown assets.

The CI workflow uses the normal `docker` Forgejo runner label and does not
consume deployment secrets.

### `cd.yml`

Runs only for:

- pushes to `master`;
- `v*` tags;
- explicit manual dispatches.

It builds the repository Dockerfile once and publishes it to the Forgejo
container registry with an immutable SHA tag. `master` also publishes `latest`,
and a `v*` Git tag publishes the corresponding OCI tag.

Examples:

```text
git.starintel.actor/starintel-labs/nitter:sha-0123456789ab
git.starintel.actor/starintel-labs/nitter:latest
git.starintel.actor/starintel-labs/nitter:v1.2.3
```

The registry host defaults to the host in `FORGEJO_SERVER_URL`. Set the Forgejo
Actions variable `CONTAINER_REGISTRY` only when the OCI registry is served from
a different hostname.

## Runner requirements

### `docker`

The CI runner must expose the Forgejo label `docker` and support the Docker
backend, because the jobs select pinned Nim container images.

### `docker-publish`

The delivery runner must expose the label `docker-publish` and provide both
`git` and a working Docker client/daemon. Keeping image publication on a
separate runner label prevents an ordinary PR build runner from automatically
becoming a deployment-capable machine.

## Required delivery secrets

Configure these at the repository or organization Actions-secret level:

```text
REGISTRY_USER
REGISTRY_TOKEN
```

`REGISTRY_TOKEN` needs permission to publish container packages for the
`starintel-labs` owner. Do not expose these secrets to the PR workflow.

## Optional variable

```text
CONTAINER_REGISTRY
```

Use this only if the registry hostname differs from the Forgejo application
hostname.

## Design notes

The repository intentionally keeps GitHub and Forgejo workflow files separate.
`.github/workflows/` remains useful for upstream compatibility, while
`.forgejo/workflows/` is authoritative for StarIntel's Forgejo CI/CD.

The delivery workflow is continuous **delivery** to the OCI registry. Runtime
deployment should consume the immutable `sha-*` image tag (or its digest) from
the infrastructure repository rather than giving this application repository
SSH credentials to production hosts.
