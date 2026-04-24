# syntax=docker/dockerfile:1
# =============================================================================
# Finance Automation Sandbox — Ephemeral Docker Container
# Used by OpenClaw's native Docker sandboxing (agents.defaults.sandbox.mode)
# to execute all agent tool commands in an isolated, ephemeral environment.
# =============================================================================
FROM node:24-alpine

# No network access inside the sandbox (enforced by OpenClaw at runtime
# via --network=none). This layer sets a minimal read-only OS environment.
RUN apk add --no-cache \
      python3 \
      py3-pip \
      bash \
      curl \
      jq

# Create a non-root sandbox user
RUN addgroup -S sandbox && adduser -S -G sandbox sandbox

# Set working directory — OpenClaw mounts skill workspaces here
WORKDIR /workspace

# Install lightweight Python utilities used by skills
COPY requirements-sandbox.txt /tmp/requirements-sandbox.txt
RUN pip3 install --no-cache-dir -r /tmp/requirements-sandbox.txt

# Switch to non-root user for all skill execution
USER sandbox

# Default entrypoint — OpenClaw overrides this with the specific skill command
ENTRYPOINT ["/bin/bash"]
