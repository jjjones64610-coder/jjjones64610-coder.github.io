---
name: token
description: OmniRoute AI gateway toolkit (from github.com/cheaper-inference/OmniRoute). Use when working with an OmniRoute server or CLI, for token saving (RTK/Caveman prompt compression, response cache), token budgets, quotas and cost/usage logs, API keys and auth tokens, provider connections, model routing combos and fallbacks, OpenAI-compatible inference through OmniRoute, its MCP/A2A servers, tunnels, backups, webhooks, or configuring Codex CLI against it. Also when the user says "token" or "/token".
---

# token: OmniRoute skill bundle

This bundles all 46 agent skills from [cheaper-inference/OmniRoute](https://github.com/cheaper-inference/OmniRoute)
(`skills/`, commit 3e23a8a). OmniRoute is a local or remote AI gateway with an OpenAI-compatible REST API, a CLI
(`omniroute`), an MCP server and an A2A server.

## How to use this skill

1. Find the row below that matches the task, then read that reference file in full before acting. Load only the files you need.
2. Everything here needs a running OmniRoute instance. Default base URL: `http://localhost:20128`.
   - REST: set `OMNIROUTE_URL` and a Bearer key (`OMNIROUTE_KEY` / `OMNIROUTE_TOKEN`). Start with `omni-auth`.
   - CLI: `npm install -g omniroute` or `npx omniroute`. Start with `cli-serve`.
   - Check it is up with `curl $OMNIROUTE_URL/api/health`.
3. If no server is reachable, say so and ask the user for the URL and key. Don't invent responses.
4. Never put real API keys in committed files. Read them from environment variables.

Quick picks for token savings and spend: `omni-compression`, `omni-context-rtk`, `omni-cache`, `omni-budget`,
`omni-usage-logs`, `cli-compression`, `cli-cost-usage`.

## API skills (REST)

| ID | File | What it covers |
| --- | --- | --- |
| `omni-agents-a2a` | [references/omni-agents-a2a/omni-agents-a2a.md](references/omni-agents-a2a/omni-agents-a2a.md) | Interact with OmniRoute via JSON-RPC 2.0 agent-to-agent protocol. 6 built-in A2A skills: smart-routing, quota-management, provider-discovery, cost-analysis, health-report, list-capabilities. |
| `omni-api-keys` | [references/omni-api-keys/omni-api-keys.md](references/omni-api-keys/omni-api-keys.md) | Create, list, rotate, and revoke OmniRoute API keys. Control per-key scopes, spending limits, and expiration. Keys gate access to all proxy and management endpoints. |
| `omni-auth` | [references/omni-auth/omni-auth.md](references/omni-auth/omni-auth.md) | Manage API key authentication and session tokens. Start here to authenticate requests via Bearer token, obtain session cookies, and configure login requirements for the OmniRoute API. |
| `omni-budget` | [references/omni-budget/omni-budget.md](references/omni-budget/omni-budget.md) | Configure spending limits, token quotas, and rate-limit policies per API key or globally. Inspect current consumption and enforce cost controls across providers. |
| `omni-cache` | [references/omni-cache/omni-cache.md](references/omni-cache/omni-cache.md) | Manage the LLM response cache. View cache statistics, list and clear entries, and inspect or clear the reasoning replay cache. |
| `omni-cli-tools` | [references/omni-cli-tools/omni-cli-tools.md](references/omni-cli-tools/omni-cli-tools.md) | Manage CLI tool integrations exposed via the API. List, configure, and invoke CLI tool plugins that extend OmniRoute's automation surface. |
| `omni-combos-routing` | [references/omni-combos-routing/omni-combos-routing.md](references/omni-combos-routing/omni-combos-routing.md) | Create and manage routing combos with every strategy (priority, weighted, round-robin, Auto-combo, and more). Configure fallback chains, test routing outcomes, and retrieve combo metrics. |
| `omni-compression` | [references/omni-compression/omni-compression.md](references/omni-compression/omni-compression.md) | Configure RTK (command output), Caveman (prose), and stacked compression modes. Manage language packs, custom rules, and test prompt compression reducing tokens by 60–90%. |
| `omni-context-rtk` | [references/omni-context-rtk/omni-context-rtk.md](references/omni-context-rtk/omni-context-rtk.md) | Configure RTK filters, context engineering rules, and context relay settings. Test compression with real prompt samples and manage context transformation pipelines. |
| `omni-db-backups` | [references/omni-db-backups/omni-db-backups.md](references/omni-db-backups/omni-db-backups.md) | List and export database backups. Also covers the system version, metrics and environment-repair routes. |
| `omni-github-skills` | [references/omni-github-skills/omni-github-skills.md](references/omni-github-skills/omni-github-skills.md) | Search, score, scan, and import agent skills from GitHub repositories that contain SKILL.md, CLAUDE.md, .cursorrules, and similar agent skill files. Discover community skills across many tool and provider categories, evaluate relevance with heuristic scoring, check for malware or hardcoded secrets, and install into Hermes, Claude Code, Gemini CLI, or OpenCode agent directories. |
| `omni-inference` | [references/omni-inference/omni-inference.md](references/omni-inference/omni-inference.md) | The core OpenAI-compatible inference endpoints: chat completions, embeddings, images, audio (TTS/STT), moderations, rerank, and the Responses API. The primary integration surface for AI agents. |
| `omni-mcp` | [references/omni-mcp/omni-mcp.md](references/omni-mcp/omni-mcp.md) | Connect to the OmniRoute MCP server (3 transports: SSE/stdio/HTTP). Covers routing, cache, compression, memory, skills, providers, and audit tools across its permission scopes. |
| `omni-models` | [references/omni-models/omni-models.md](references/omni-models/omni-models.md) | Query available AI models across all configured providers. List models, resolve model aliases, and browse the full model catalog including provider-specific variants. |
| `omni-providers` | [references/omni-providers/omni-providers.md](references/omni-providers/omni-providers.md) | Manage provider connections, API keys, OAuth flows, and connection tests via the REST API. List, add, update, remove, and test AI provider integrations across OmniRoute's provider catalog. |
| `omni-proxies` | [references/omni-proxies/omni-proxies.md](references/omni-proxies/omni-proxies.md) | Configure HTTP/HTTPS/SOCKS proxies for upstream provider requests. Set per-provider or global proxy rules, test connectivity, and manage proxy rotation. |
| `omni-resilience` | [references/omni-resilience/omni-resilience.md](references/omni-resilience/omni-resilience.md) | Monitor provider health, circuit-breaker states, p50/p95/p99 latency metrics, and budget guard alerts. Inspect connection cooldowns and model lockouts in real time. |
| `omni-settings` | [references/omni-settings/omni-settings.md](references/omni-settings/omni-settings.md) | Read and update global application settings: system prompts, thinking budget, IP filters, payload rules, combo defaults, and require-login configuration. |
| `omni-sync-cloud` | [references/omni-sync-cloud/omni-sync-cloud.md](references/omni-sync-cloud/omni-sync-cloud.md) | Synchronise OmniRoute configuration, provider connections, and settings to/from cloud storage. Manage cloud worker authentication and remote backup targets. |
| `omni-tunnels` | [references/omni-tunnels/omni-tunnels.md](references/omni-tunnels/omni-tunnels.md) | Create and manage secure tunnels (ngrok, Cloudflare Tunnel, custom) to expose OmniRoute to the internet or share access with remote agents and CI pipelines. |
| `omni-usage-logs` | [references/omni-usage-logs/omni-usage-logs.md](references/omni-usage-logs/omni-usage-logs.md) | Access detailed call logs and usage analytics. Filter by provider, model, time range, status, and cost. Export logs and aggregate token usage across all connections. |
| `omni-version-manager` | [references/omni-version-manager/omni-version-manager.md](references/omni-version-manager/omni-version-manager.md) | Install, start, stop, restart, and update embedded services (9Router, CLIProxyAPI). Monitor service status, retrieve logs, and configure auto-start for local-only service endpoints. |
| `omni-webhooks` | [references/omni-webhooks/omni-webhooks.md](references/omni-webhooks/omni-webhooks.md) | Register, list, test, and remove webhook endpoints. Configure event subscriptions (request.completed, request.failed, quota.exceeded, etc.) and manage delivery retries. |

## CLI skills

| ID | File | What it covers |
| --- | --- | --- |
| `cli-a2a` | [references/cli-a2a/cli-a2a.md](references/cli-a2a/cli-a2a.md) | Interact with the OmniRoute A2A server from the CLI. Send tasks, inspect skill execution history, and test the JSON-RPC 2.0 agent-to-agent protocol interactively. |
| `cli-backup-sync` | [references/cli-backup-sync/cli-backup-sync.md](references/cli-backup-sync/cli-backup-sync.md) | Backup and restore OmniRoute data from the CLI. Trigger incremental snapshots, sync to cloud storage, manage backup schedules, and restore from archive files. |
| `cli-batches` | [references/cli-batches/cli-batches.md](references/cli-batches/cli-batches.md) | Submit and monitor batch inference jobs from the CLI. Upload and manage files for batch processing, retrieve results, and integrate batch pipelines with CI/CD workflows. |
| `cli-chat` | [references/cli-chat/cli-chat.md](references/cli-chat/cli-chat.md) | Send chat completions, stream responses, and start an interactive REPL session from the CLI. Supports all OmniRoute providers, combo routing, and system prompt configuration. |
| `cli-compression` | [references/cli-compression/cli-compression.md](references/cli-compression/cli-compression.md) | Configure and test prompt compression from the CLI. Manage RTK filters, Caveman rules, stacked compression modes, and preview compression output with real prompts. |
| `cli-contexts` | [references/cli-contexts/cli-contexts.md](references/cli-contexts/cli-contexts.md) | Manage context engineering configurations, RTK filter sets, and conversation sessions from the CLI. Apply context-relay settings and inspect active context pipelines. |
| `cli-cost-usage` | [references/cli-cost-usage/cli-cost-usage.md](references/cli-cost-usage/cli-cost-usage.md) | View cost breakdowns, token usage, and call logs from the CLI. Filter by provider, model, or date range. Export usage reports and inspect per-connection spending. |
| `cli-eval` | [references/cli-eval/cli-eval.md](references/cli-eval/cli-eval.md) | Create and run evaluation suites, watch live benchmark progress, view scorecards, compare model performance, and integrate eval runs with CI workflows from the CLI. |
| `cli-health` | [references/cli-health/cli-health.md](references/cli-health/cli-health.md) | Check server health, component status, and live metrics from the CLI. Run `health`, `health components`, and `health watch` for a real-time dashboard of circuit breakers and provider status. |
| `cli-keys` | [references/cli-keys/cli-keys.md](references/cli-keys/cli-keys.md) | Create, list, rotate, and revoke OmniRoute API keys from the CLI. Manage OAuth flows for provider authentication and inspect key scopes and expiration. |
| `cli-mcp` | [references/cli-mcp/cli-mcp.md](references/cli-mcp/cli-mcp.md) | Inspect the MCP server status, list registered tools and scopes, run tool invocations, and manage MCP audit logs from the CLI. |
| `cli-models` | [references/cli-models/cli-models.md](references/cli-models/cli-models.md) | Query available AI models, list model aliases, and browse the full model catalog from the CLI. Filter by provider, search by capability, and resolve model name variants. |
| `cli-plugins-skills` | [references/cli-plugins-skills/cli-plugins-skills.md](references/cli-plugins-skills/cli-plugins-skills.md) | Manage Omni Skills (list, install, test, remove), plugins (create, configure), and persistent memory (search, add, clear) from the CLI. |
| `cli-policy-audit` | [references/cli-policy-audit/cli-policy-audit.md](references/cli-policy-audit/cli-policy-audit.md) | Inspect audit logs, manage access policies, view telemetry data, and review request history from the CLI. Filter by event type, user, or time range for compliance workflows. |
| `cli-providers` | [references/cli-providers/cli-providers.md](references/cli-providers/cli-providers.md) | Manage provider connections from the CLI: list available/configured providers, add, test, test-all, validate, rotate API keys, and view per-provider metrics. |
| `cli-resilience` | [references/cli-resilience/cli-resilience.md](references/cli-resilience/cli-resilience.md) | Inspect and manage circuit-breaker states, connection cooldowns, quota limits, and backoff levels from the CLI. Reset stuck providers and configure resilience thresholds. |
| `cli-routing` | [references/cli-routing/cli-routing.md](references/cli-routing/cli-routing.md) | Create, list, update, and delete routing combos from the CLI. Test routing strategies, inspect combo metrics, and configure fallback chains interactively. |
| `cli-serve` | [references/cli-serve/cli-serve.md](references/cli-serve/cli-serve.md) | Start, stop, and restart the OmniRoute server from the CLI. Manage daemon mode, port configuration, auto-recovery, system tray integration, and the dashboard open shortcut. |
| `cli-setup` | [references/cli-setup/cli-setup.md](references/cli-setup/cli-setup.md) | Run initial setup, configure global CLI settings, manage environment variables, check for updates, and configure autostart via the CLI setup and config commands. |
| `cli-skill-collector` | [references/cli-skill-collector/cli-skill-collector.md](references/cli-skill-collector/cli-skill-collector.md) | Detect installed CLI coding tools (Claude Code, Codex, Cursor, Copilot, Cline and more), search GitHub for matching agent skills, and install them to the detected tools via OmniRoute's built-in APIs. |
| `cli-tunnel` | [references/cli-tunnel/cli-tunnel.md](references/cli-tunnel/cli-tunnel.md) | Start and stop tunnel connections (ngrok, Cloudflare, custom) from the CLI. Inspect active tunnel URLs, configure authentication, and test external reachability. |
| `config-codex-cli` | [references/config-codex-cli/config-codex-cli.md](references/config-codex-cli/config-codex-cli.md) | Step-by-step agent workflow to configure the OpenAI Codex CLI on any machine (Linux, macOS, Windows) to use OmniRoute as an OpenAI-compatible backend. Detects OS and shell, writes config.toml and 7 named profiles, sets environment variables, and verifies the setup. |

## Other

| ID | File | What it covers |
| --- | --- | --- |
| `ponytail` | [references/ponytail/ponytail.md](references/ponytail/ponytail.md) | A third-party coding-style persona (MIT, DietrichGebert/ponytail) that pushes for the most minimal solution. It is not part of OmniRoute. Load it only when the user explicitly asks for ponytail, lazy mode or minimal-solution mode. |
