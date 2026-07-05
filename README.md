# Sikker Selvbetjening Config

## Podman Socket Pattern In CI

This repository uses a shared Podman socket pattern in CI to ensure image build and push use the same image store.

### Why this is needed

The build logic runs inside a container from the base image. Without socket sharing, the inner container engine can build/tag images that the host Podman engine cannot see. That leads to push errors such as `image not known`.

### How it works here

The script [scripts/build-image.sh](scripts/build-image.sh):

1. Starts (or reuses) a host Podman API socket.
2. Waits for socket readiness.
3. Mounts the host socket into the validator container.
4. Sets `CONTAINER_HOST` in the container to the mounted socket.
5. Reads emitted `PUSH_REFS` and pushes each ref with host Podman.

This makes build, tag, and push happen against one shared Podman engine context.

### Operational notes

1. This is a known and valid pattern (often called engine socket sharing / outside-of-container engine access).
2. It is more complex than single-engine flows but avoids cross-context image visibility issues.
3. Mounting the engine socket is a privileged capability; use only in trusted CI contexts.

## Use As Template

This repository is intended to be copied and used as a tenant-specific configuration and publishing project.

### 1. Create a new repository from this template

1. Use GitHub template/copy flow to create your own repository.
2. Add your tenant folders under `config/`.
3. For each tenant, keep this structure:
	1. `config/<tenant>/imageconfigs/*.yml`
	2. `config/<tenant>/policies/*.yml`
	3. `config/<tenant>/assets/*`

### 2. Verify GitHub Actions permissions

The workflow pushes images with `GITHUB_TOKEN`, so the repository must allow package writes.

1. In your repository settings, ensure Actions workflow permissions allow write access.
2. Keep workflow permissions including `packages: write`.

### 3. Image publishing namespace

The workflow publishes to:

1. `ghcr.io/${{ github.repository }}`

This means template copies publish into their own namespace automatically.

Example for repo `agnete-allmail/my-sikker-selvbetjening-config`:

1. `ghcr.io/agnete-allmail/my-sikker-selvbetjening-config/<tenant>/<image_id>:latest`

### 4. Run the workflow

Workflow: `Build and Push Tenant Images`

Optional workflow_dispatch inputs:

1. `tenant`: limit to one tenant (for example `bibliotek`)
2. `imageconfig_file`: limit to one imageconfig filename (for example `boernebibliotek.yml`)

If no inputs are provided, all tenant imageconfigs are discovered and processed.