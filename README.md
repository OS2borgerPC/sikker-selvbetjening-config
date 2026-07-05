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

C