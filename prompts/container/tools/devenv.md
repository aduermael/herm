---
name: devenv
description: Manage the dev container Dockerfile at .herm/Dockerfile
runs_on: container
---

Manage the single dev container Dockerfile at .herm/Dockerfile. The built image replaces the running container and persists across sessions. This is the ONLY way to install tools persistently — ad-hoc bash installs are ephemeral.

**Base image:** `FROM aduermael/herm:__HERM_VERSION__` (mandatory, placeholder resolved at build time). Current image: __CONTAINER_IMAGE__.

**Mandatory workflow: read → write → build.** Never skip read. Run `devenv read` for full Dockerfile guidelines and installation examples.

ONE Dockerfile per project. Extend it — never create a parallel one. Combine related RUN steps: `apt-get update && apt-get install -y ... && rm -rf /var/lib/apt/lists/*`.
