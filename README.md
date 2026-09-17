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
- Docker with the [buildx plugin](https://docs.docker.com/buildx/working-with-buildx/) (required for container image targets)

## Running locally

```bash
# Build
./mvnw clean package -DskipTests

# Run in dev mode
./mvnw quarkus:dev
```

Server starts on `http://localhost:8081`

## Container images

```bash
# Build a local image
make image IMAGE_NAME=quay.io/causa-ai-hub/causa-mcp IMAGE_TAG=0.0.1

# Authenticate with the registry before pushing
docker login quay.io

# Build and push a multi-arch image
make image-multiarch IMAGE_NAME=quay.io/causa-ai-hub/causa-mcp IMAGE_TAG=0.0.1
```

The multi-arch target publishes both `linux/amd64` and `linux/arm64`. Override `PLATFORMS` if needed.

## Configuration

| Property | Default | Description |
|---|---|---|
| `quarkus.http.port` | `8081` | MCP server port |
| `CAUSA_ENGINE_URL` | `http://localhost:8080` | Causa Engine base URL |

