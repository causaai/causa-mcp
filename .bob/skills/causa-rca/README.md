# Causa RCA Skill for Bob — User Guide

AI-powered root cause analysis for Kubernetes workloads, delivered directly in your coding environment through Bob.

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Prerequisites](#prerequisites)
4. [Setup](#setup)
   - [Step 1 — Deploy Causa Backend](#step-1--deploy-causa-backend)
   - [Step 2 — Deploy Causa MCP Server](#step-2--deploy-causa-mcp-server)
   - [Step 3 — Connect Bob to Causa MCP](#step-3--connect-bob-to-causa-mcp)
   - [Step 4 — Install the Skill](#step-4--install-the-skill)
5. [Deploy a Test Workload](#deploy-a-test-workload)
   - [Deploy quarkus-perf](#deploy-quarkus-perf)
   - [Enable a Chaos Scenario](#enable-a-chaos-scenario)
   - [Start the Load Generator](#start-the-load-generator)
6. [Using the Skill](#using-the-skill)
   - [Intent Types](#intent-types)
   - [Example Conversations](#example-conversations)
7. [How It Works](#how-it-works)
   - [Application Discovery](#application-discovery)
   - [Workflow](#workflow)
   - [Output Format](#output-format)
8. [Troubleshooting](#troubleshooting)

---

## Overview

The **causa-rca** skill teaches Bob how to perform root cause analysis on failing Kubernetes applications. Instead of switching between dashboards, logs, and CLIs, developers can ask Bob natural-language questions like *"Why is my app crashing?"* and get a structured diagnosis with root cause, evidence, confidence score, and fix recommendations — all without leaving their editor.

The skill connects Bob to the **Causa Engine** via the **Causa MCP Server**, using the Model Context Protocol (MCP) standard.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Developer's Machine                                            │
│                                                                 │
│  ┌───────────┐      ┌──────────────────────────────────────┐    │
│  │   Bob      │─────►│  Causa MCP Server (localhost:8081)   │    │
│  │  (AI Agent)│ MCP  │  Port-forwarded from cluster         │    │
│  │  + Skill   │◄─────│  Tools: initiate_rca, get_rca_status,│    │
│  └───────────┘      │         get_rca_result               │    │
│                      └──────────────┬───────────────────────┘    │
└─────────────────────────────────────┼────────────────────────────┘
                                      │ REST (port 8080)
┌─────────────────────────────────────┼────────────────────────────┐
│  Kubernetes Cluster                 │                             │
│                                     ▼                             │
│  ┌──────────────────────────────────────────┐                    │
│  │  Causa Engine (causa-backend)             │                    │
│  │  - Receives alerts                        │                    │
│  │  - Collects K8s events, metrics, logs     │                    │
│  │  - Runs RCA pipeline                      │                    │
│  │  - Returns structured diagnosis           │                    │
│  └──────────────┬───────────────────────────┘                    │
│                 │ collects from                                   │
│    ┌────────────┼────────────┬──────────────┐                    │
│    ▼            ▼            ▼              ▼                    │
│  ┌──────┐  ┌────────┐  ┌────────┐  ┌─────────────┐             │
│  │ K8s  │  │ Kruize │  │ Prom/  │  │ Application │             │
│  │Events│  │  (reco) │  │Metrics│  │   Logs      │             │
│  └──────┘  └────────┘  └────────┘  └─────────────┘             │
│                                                                  │
│  ┌──────────────────────────────────────────┐                    │
│  │  Target Workloads (e.g., quarkus-perf)   │                    │
│  │  - Banking + Airline booking app          │                    │
│  │  - Chaos knobs for failure simulation     │                    │
│  └──────────────────────────────────────────┘                    │
└──────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

- **Kubernetes cluster** (OpenShift or kind)
- **kubectl** configured and connected to the cluster
- **Bob** installed on your machine
- **Causa Engine** deployed in the cluster
- **Causa MCP Server** deployed in the cluster

---

## Setup

### Step 1 — Deploy Causa Backend

The Causa Engine must be running in your cluster. It handles alert ingestion, data collection, and RCA generation.

```bash
# Verify causa-backend is running
kubectl get pods -n causa-demo -l app=causa-backend
```

### Step 2 — Deploy Causa MCP Server

The MCP server acts as a bridge between Bob and the Causa Engine. It exposes three MCP tools:

| Tool | Description |
|------|-------------|
| `initiate_rca` | Sends a synthetic alert to Causa Engine, returns a `diagnostic_id` |
| `get_rca_status` | Polls for the current status of a running analysis |
| `get_rca_result` | Retrieves the full RCA result once completed |

```bash
# Verify causa-mcp-server is running
kubectl get pods -n openshift-tuning -l app=causa-mcp-server
```

### Step 3 — Connect Bob to Causa MCP

Port-forward the MCP server to your local machine:

```bash
kubectl port-forward svc/causa-mcp-server-svc 8081:8081 -n openshift-tuning
```

Configure Bob's MCP settings at `~/.bob/settings/mcp.json`:

```json
{
  "mcpServers": {
    "causa-mcp": {
      "url": "http://localhost:8081/mcp/sse"
    }
  }
}
```

Verify the connection:

```bash
curl -s http://localhost:8081/mcp/sse --max-time 3
# Should return: event: endpoint
```

### Step 4 — Install the Skill

The skill file is located at `.bob/skills/causa-rca/SKILL.md` in the chaos-lab repository. Bob automatically loads skills from the `.bob/skills/` directory when launched from the project root.

```bash
cd /path/to/chaos-lab
bob   # Start Bob from this directory
```

To use the skill in other projects, copy the `.bob/skills/causa-rca/` directory into that project's `.bob/skills/` folder.

---

## Deploy a Test Workload

### Deploy quarkus-perf

`quarkus-perf` is a Quarkus application that simulates a banking and airline booking backend with tunable chaos knobs for JVM heap pressure, connection-pool exhaustion, slow-query latency, and HTTP misconfiguration.

```bash
# Deploy to causa-demo namespace
cat quarkus-perf/manifests/deploy.yaml \
  | sed 's/namespace: chaos-test/namespace: causa-demo/g' \
  | kubectl apply -f -

# Verify pods are running
kubectl get pods -n causa-demo -l app=quarkus-perf
```

### Enable a Chaos Scenario

**Scenario: Memory Leak (OOMKill)**

Each transaction leaks ~320KB of heap. Under sustained load, pods get OOMKilled.

```bash
kubectl patch configmap quarkus-perf-config -n causa-demo \
  --type merge -p '{"data":{
    "CHAOS_MEMORY_CACHE_ENABLED":"true",
    "CHAOS_MEMORY_OBJECTS_PER_TX":"5"
  }}'

kubectl rollout restart deployment/quarkus-perf -n causa-demo
```

**Scenario: Connection Pool Exhaustion**

DB connections are acquired but never returned. Pool exhausts after ~10 requests.

```bash
kubectl patch configmap quarkus-perf-config -n causa-demo \
  --type merge -p '{"data":{
    "CHAOS_DB_LEAK_ENABLED":"true",
    "DB_MAX_POOL_SIZE":"10"
  }}'

kubectl rollout restart deployment/quarkus-perf -n causa-demo
```

**Scenario: Slow Queries + Thread Starvation**

```bash
kubectl patch configmap quarkus-perf-config -n causa-demo \
  --type merge -p '{"data":{
    "CHAOS_DB_SLOW_QUERY_MS":"500",
    "THREAD_POOL_MAX":"50"
  }}'

kubectl rollout restart deployment/quarkus-perf -n causa-demo
```

**Reset to normal:**

```bash
kubectl patch configmap quarkus-perf-config -n causa-demo \
  --type merge -p '{"data":{
    "CHAOS_MEMORY_CACHE_ENABLED":"false",
    "CHAOS_DB_LEAK_ENABLED":"false",
    "CHAOS_DB_SLOW_QUERY_MS":"0",
    "THREAD_POOL_MAX":"200",
    "DB_MAX_POOL_SIZE":"20"
  }}'

kubectl rollout restart deployment/quarkus-perf -n causa-demo
```

### Start the Load Generator

```bash
cat quarkus-perf/manifests/load-gen-job.yaml \
  | sed 's/namespace: chaos-test/namespace: causa-demo/g' \
  | kubectl apply -f -

# Follow load generator logs
kubectl logs -n causa-demo -l app=quarkus-perf-load-gen -f
```

---

## Using the Skill

### Intent Types

The skill recognizes three types of developer intent:

| Intent | When to use | What happens |
|--------|-------------|--------------|
| **QUERY** | You want to see existing results | Checks for completed RCA and presents it. Never starts a new analysis. |
| **INVESTIGATE** | You have a problem and want answers | Checks for existing results first. Uses them if available, starts a new analysis only if needed. |
| **FORCE_RUN** | You explicitly want a fresh analysis | Starts a new analysis immediately. Use after changing chaos scenarios or deployments. |

### Example Conversations

**Investigate a crash:**

```
You:  Why is my quarkus-perf app crashing?
Bob:  [discovers live pods] → [checks existing RCA] → [initiates new RCA]
      → [polls for completion] → [presents structured result]
```

**Check for existing results:**

```
You:  Any RCA available for quarkus-perf?
Bob:  [finds completed RCA] → [presents result]
      — or —
      "No existing RCA found for quarkus-perf. Would you like me to start one?"
```

**Force a fresh analysis:**

```
You:  Run RCA again
Bob:  [starts new analysis immediately] → [polls] → [presents result]
```

**Ask a specific question:**

```
You:  Is there a memory issue with quarkus-perf?
Bob:  [checks existing RCA] → [leads with memory-related findings]
      → [shows full structured result]
```

**Without specifying an app:**

```
You:  Run RCA
Bob:  "Here are the workloads currently running in causa-demo:
       - quarkus-perf
       - heap-oom
       - system-oom
       Which one should I run RCA on?"
```

---

## How It Works

### Application Discovery

The skill always checks **live pods** in the cluster before acting. It runs `kubectl get pods` to discover what's currently running — it does not rely on stale conversation history or hardcoded application names.

If the developer specifies an app, the skill validates it against the live pod list. If the pod no longer exists, the skill shows what's currently running and asks the developer to choose.

### Workflow

```
Developer asks a question
        │
        ▼
┌─────────────────┐
│ Classify Intent  │
│ QUERY / INVEST-  │
│ IGATE / FORCE_RUN│
└────────┬────────┘
         │
         ▼
┌─────────────────┐     ┌──────────────────┐
│ Discover Live    │────►│ Match or ask      │
│ Pods (kubectl)   │     │ developer to pick │
└────────┬────────┘     └──────────────────┘
         │
         ▼
┌─────────────────┐  FORCE_RUN   ┌──────────────────┐
│ Check Existing   │────────────►│ Initiate New RCA  │
│ Diagnostics      │             └────────┬─────────┘
└────────┬────────┘                       │
         │                                │
    Found existing?                       ▼
    ┌────┴────┐                  ┌──────────────────┐
    Yes       No ────────────►   │ Poll for Result   │
    │                            │ (5s intervals,    │
    │                            │  max 2 min)       │
    ▼                            └────────┬─────────┘
┌──────────────┐                          │
│ Present       │                          ▼
│ Existing      │◄────────────── ┌──────────────────┐
│ Result        │                │ Render Structured │
└──────────────┘                │ Output            │
                                 └──────────────────┘
```

### Output Format

When results are available, the skill presents them in a structured format:

| Section | Content |
|---------|---------|
| **Executive Summary** | 2-3 sentences: what happened, why, and urgency |
| **Impact Assessment** | Severity, affected workload, current status |
| **Root Cause** | 1-3 sentences from the RCA engine |
| **Key Evidence** | Bullet list of concrete observations (exit codes, events, metrics) |
| **Confidence** | Percentage score with explanation |
| **Recommended Fix** | Ordered: Immediate Mitigation, Root Cause Fix, Validate & Monitor |
| **Suggested Code Changes** | Config/YAML snippets when applicable |
| **Next Steps** | Numbered action items |

---

## Troubleshooting

### Bob can't connect to Causa MCP

```bash
# Check if port-forward is alive
curl -s http://localhost:8081/mcp/sse --max-time 3

# If dead, kill stale process and restart
lsof -ti:8081 | xargs kill -9
kubectl port-forward svc/causa-mcp-server-svc 8081:8081 -n openshift-tuning
```

### Bob doesn't load the skill

- Make sure you're running Bob **from the chaos-lab directory** (or whichever project has `.bob/skills/causa-rca/`)
- Start a **new Bob session** after adding/editing the skill — skills are loaded at session start

### RCA times out (> 2 minutes)

The Causa Engine collects data from multiple sources (K8s events, Kruize recommendations, metrics). Kruize recommendations can take up to 30 minutes to generate if they haven't been cached yet.

If the skill reports a timeout, it provides the `diagnostic_id`. Ask again later:

```
You:  Any RCA available for quarkus-perf?
Bob:  [finds the completed result and presents it]
```

### "No existing RCA found" when one should exist

The RCA may have been run against a different pod name (pods get new names after restarts). The skill checks by exact pod name. Run a fresh analysis:

```
You:  Run RCA for quarkus-perf
```

### Causa MCP pod is not running

```bash
# Check pod status
kubectl get pods -n openshift-tuning -l app=causa-mcp-server

# Check logs
kubectl logs -n openshift-tuning deployment/causa-mcp-server
```

### Resetting chaos scenarios

After switching chaos scenarios, always restart the deployment and run a fresh RCA:

```bash
# Patch the configmap with new chaos settings
kubectl patch configmap quarkus-perf-config -n causa-demo \
  --type merge -p '{"data":{"CHAOS_MEMORY_CACHE_ENABLED":"false"}}'

# Restart pods
kubectl rollout restart deployment/quarkus-perf -n causa-demo

# In Bob:
# "Run RCA again" (FORCE_RUN intent to get fresh analysis)
```
