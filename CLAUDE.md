# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**edgetunnel** is a single-file Cloudflare Worker proxy service that implements VLESS, Trojan, and Shadowsocks protocols with an integrated admin panel and subscription generation. The entire application lives in `_worker.js` (~3500 lines).

## Development Commands

This project has **no build step, no test suite, and no package manager dependencies**. Development relies on the Wrangler CLI.

- **Local dev server**: `npx wrangler dev` (or `bunx wrangler dev`)
- **Deploy to Workers**: `npx wrangler deploy`
- **Tail logs**: `npx wrangler tail`

### Required Setup for Local Development

1. Install Wrangler CLI globally or use `npx`/`bunx`.
2. Authenticate with Cloudflare: `npx wrangler login`
3. Bind a KV namespace for local dev (create in Cloudflare dashboard, then add to `wrangler.toml`):
   ```toml
   [[kv_namespaces]]
   binding = "KV"
   id = "your-kv-namespace-id"
   ```
4. Set secrets via Wrangler:
   - `npx wrangler secret put ADMIN` (admin panel password, **required**)
   - `npx wrangler secret put UUID` (optional, forces fixed UUID)
   - `npx wrangler secret put PROXYIP` (optional, custom proxy IP)

## Architecture

### Single-File Monolith

All logic resides in `_worker.js`. The export default `fetch` handler is the single entry point. It routes requests based on pathname, headers (Upgrade, Content-Type), and query parameters:

1. **Proxy protocols** (matched first by headers)
   - `Upgrade: websocket` → `处理WS请求()` (VLESS/Trojan/SS over WebSocket)
   - `content-type: application/grpc` → `处理gRPC请求()`
   - POST with XHTTP padding signature → `处理XHTTP请求()`
2. **Admin & subscriptions** (matched by pathname)
   - `/admin` and `/admin/*` → cookie-authenticated admin panel & API
   - `/sub` → subscription generation (Clash, Sing-box, Surge, mixed)
   - `/login`, `/logout` → session management
3. **Fallback** → camouflage page proxy (`env.URL`) or default nginx-like page

### Key Subsystems

- **Protocol handlers** (`处理WS请求`, `处理gRPC请求`, `处理XHTTP请求`): parse VLESS/Trojan/SS initial packets, establish outbound TCP/UDP connections via `connect` from `cloudflare:sockets`, and bridge traffic between the client and remote host.
- **SOCKS5/HTTP proxy chaining** (`socks5Connect`, `httpConnect`, `反代参数获取`): optional upstream proxy support configured via environment variables or URL query parameters.
- **Subscription generation**: dynamically builds node lists from local random IPs, external优选APIs, or优选订阅生成器 hosts, and outputs base64/VLESS links or converts via subconverter APIs.
- **Config management** (`读取config_JSON`): merges environment variables with KV-stored `config.json`, `cf.json`, `tg.json`, and `ADD.txt` into a single configuration object used by the admin panel and subscription endpoints.
- **Admin panel UI**: the frontend HTML/JS/CSS is **not** in this repo; it is fetched at runtime from `Pages静态页面` (`https://edt-pages.github.io`). The worker only serves the API backend for the panel.

### State & Storage

- **KV**: used for persisting `config.json`, `cf.json`, `tg.json`, `ADD.txt`, and `log.json`. The binding name must be `KV`.
- **No local state**: the worker is stateless except for in-memory caches (e.g., `缓存反代IP`, `缓存反代解析数组`).

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `ADMIN` | **Required.** Admin panel login password. |
| `KEY` | Subscription path key; defaults to a hardcoded string if unset. |
| `UUID` | Optional. Forces a fixed UUIDv4 for node auth. |
| `PROXYIP` | Optional. Global custom proxy IP (e.g., `proxyip.example.com:443`). |
| `URL` | Optional. Camouflage page URL, or `1101` for a built-in error page. |
| `GO2SOCKS5` | Optional. Comma-separated domains forced through SOCKS5 (use `*` for global). |
| `DEBUG` | Optional. Set to `1` or `true` to enable `console.log` output. |
| `OFF_LOG` | Optional. Set to `1` or `true` to disable KV log recording. |
| `BEST_SUB` | Optional. Set to `1` or `true` to enable best-subscription generator mode. |

## Important Notes for Editing

- **No bundler or transpiler**: `_worker.js` is deployed as-is. It must be valid Cloudflare Worker JavaScript and can use `cloudflare:sockets` (imported at the top).
- **Compatibility date**: `wrangler.toml` pins `compatibility_date = "2025-11-04"`.
- **GitHub Action**: `.github/workflows/sync.yml` auto-syncs forks from upstream `cmliu/edgetunnel` daily.
- When modifying protocol parsing logic (VLESS/Trojan/SS), be extremely careful with byte offsets and buffer boundaries; the initial packet parsers are hand-written and sensitive to protocol spec alignment.
