# Causa MCP Server

A Quarkus-based MCP server that bridges any MCP-compatible IDE or agent with the Causa Engine for automated root cause analysis of failing Kubernetes applications.

## Overview

When a developer reports a failing app via an MCP-compatible client, the Causa MCP Server:
1. Triggers a root cause analysis on the Causa Engine
2. Polls for analysis completion
3. Returns structured RCA results for the client to surface as actionable fixes

## MCP Tools

| Tool | Description |
|---|---|
| `initiate_rca` | Triggers an RCA for a failing app and returns a `diagnostic_id` |
| `get_rca_status` | Polls RCA progress — returns `PENDING`, `RUNNING`, `COMPLETED`, or `FAILED` |
| `get_rca_result` | Returns the full RCA result including root cause, evidence, and fix recommendations |

## Prerequisites

- Java 21
- Maven 3.9+

## Running locally

```bash
# Build
./mvnw clean package -DskipTests

# Run in dev mode
./mvnw quarkus:dev
```

Server starts on `http://localhost:8081`

## Configuration

| Property | Default | Description |
|---|---|---|
| `quarkus.http.port` | `8081` | MCP server port |
| `CAUSA_ENGINE_URL` | `http://localhost:8080` | Causa Engine base URL |


## Building the container image

Builds and pushes a multi-architecture image via Quarkus Jib.

```bash
./scripts/build_and_push.sh
```

| Flag | Env var | Default | Description |
|---|---|---|---|
| `-i` | `IMAGE_NAME` | — | Full image name (`registry/group/name:tag`) |
| `-r` | `REGISTRY` | `quay.io` | Container registry |
| `-n` | `REPO_NAME` | `causa-ai-hub/causa-mcp` | Repository (`group/name`) |
| `-t` | `IMAGE_TAG` | version from `pom.xml` | Image tag |
| `-p` | `PUSH_IMAGE` | `true` | Push to registry |
| `-l` | `PLATFORMS` | `linux/amd64,linux/arm64` | Target platforms |

**Constraints**
- Multi-platform builds require push to be enabled (`PUSH_IMAGE=true`, which is the default) — Jib cannot load a multi-arch manifest into a local Docker daemon.
- Supported platforms: `linux/amd64`, `linux/arm64`.