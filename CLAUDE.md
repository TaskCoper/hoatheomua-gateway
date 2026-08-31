# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A .NET 8 ASP.NET Core **YARP reverse proxy** that fronts the HoaTheoMua backend services. It is the single public entry point: it rewrites incoming paths and forwards to downstream API clusters. It is a **pure pass-through proxy** — no authentication, no authorization, no business logic; each downstream service owns its own auth (see Authentication below). The entire app is configuration-driven proxying plus a thin DI layer.

## Commands

```bash
# Build (run from repo root; the .sln is at the root)
dotnet restore HoaTheoMua.ApiGateway.sln
dotnet build HoaTheoMua.ApiGateway.sln -c Release

# Run locally (Development env, Swagger launch URL, http://localhost:5109)
dotnet run --project HoaTheoMua.ApiGateway

# There are no test projects yet. CI has a placeholder for a `dotnet test`
# step in .github/workflows/build-image.yaml — add the step there when tests exist.
```

Docker / compose (see `.docker/`):

```bash
# Standalone single environment (base + overlay). Needs .docker/.env (copy from .env.sample).
docker compose -f .docker/docker-compose.yml -f .docker/compose.dev.yml up -d
docker compose -f .docker/docker-compose.yml -f .docker/compose.prod.yml up -d

# Profile-based compose (what CI/CD uses; can run dev + prod side by side)
docker compose -f .docker/compose.yaml --profile dev up -d
docker compose -f .docker/compose.yaml --profile prod up -d
```

## Architecture

**Request flow:** client → (Cloudflare Tunnel) → gateway `:8080` → YARP route match → path transform → downstream cluster.

- `Program.cs` is the whole pipeline: `AddReverseProxyApiGateway`, then `MapReverseProxy`. **No auth middleware** — the gateway is a pure pass-through proxy.
- DI extensions live in `DependencyInjection/Extensions/`. `ServiceCollectionExtensions.AddReverseProxyApiGateway` does `AddReverseProxy().LoadFromConfig(configuration.GetSection("ReverseProxy"))` — **all routing is config, not code.** To add/change a backend, edit the `ReverseProxy` section (see Routing below), not C#.

### Routing (the core of the app)

> Detailed routing reference (with request-transform examples and a how-to-add-a-route guide): **`docs/routing.md`**.

Defined under `ReverseProxy` in `appsettings*.json`. Two routes today, both following the same pattern:

| Incoming path                 | Cluster               | Rewritten to (sent downstream) |
| ----------------------------- | --------------------- | ------------------------------ |
| `ecommerce-api/{**catch-all}` | `ecommerceApiCluster` | `api/{**catch-all}`            |
| `taskcoper-api/{**catch-all}` | `taskcoperApiCluster` | `api/{**catch-all}`            |

The `PathPattern` transform strips the public prefix and replaces it with `api/`, so a downstream service only ever sees `api/...`. Cluster `Destinations` hold the backend base URLs. Both `appsettings.json` and `appsettings.Development.json` use the same Docker service-name addresses (`http://hoatheomua-api-dev:8080/`, `http://htm-taskcoper-api-dev:8080/`) — the JSON files are not the per-environment differentiator. Real per-environment backend addresses are injected at deploy time via the `ReverseProxy__Clusters__...__Address` env vars (`${ADDRESS_ECOMMERCE}` / `${ADDRESS_TASKCOPER}` from `.docker/.env`), which override whatever is in the JSON.

### Authentication & authorization — by design, none at the gateway

The gateway performs **no authentication and no authorization** — this is intentional, not a TODO. There is no JWT/auth middleware in `Program.cs`. Every request that matches a route is forwarded as-is; the incoming `Authorization` header is passed through to the backend by default (YARP forwards headers).

**Auth is owned entirely by each downstream service**, which validates the forwarded token and enforces its own authz. Because the services are reachable directly on the Docker network (port `8080`), they must not trust the gateway blindly — the gateway is not an auth safety net.

To add edge authentication later: re-add `AddAuthentication`/`UseAuthentication` in `Program.cs` plus a per-route `AuthorizationPolicy` in the YARP route config (`ReverseProxy:Routes:<route>:AuthorizationPolicy`), and leave public paths like login/health as `anonymous`.

## Configuration & environments

Config precedence: `appsettings.json` → `appsettings.{Environment}.json` → **environment variables** (`Program.cs` calls `AddEnvironmentVariables()` last, so env vars win).

Env vars use ASP.NET's `__` (double underscore) nesting. The compose files override the **entire** `ReverseProxy` tree this way, e.g.:

- `ReverseProxy__Clusters__ecommerceApiCluster__Destinations__Destination1__Address`

This means in deployed environments the JSON files are effectively templates — actual routes and backend addresses come from env vars / `.docker/.env` (driven by `${ADDRESS_ECOMMERCE}`, `${ADDRESS_TASKCOPER}`, etc.). Copy `.docker/.env.sample` → `.docker/.env` for local compose runs. Per-environment values are synced to GitHub environment secrets with `.docker/sync-env-secrets.sh`.

## Deployment (CI/CD)

`.github/workflows/main.yaml` is the orchestrator, triggered on push to `main` or `develop`:

1. **build-image.yaml** — `dotnet restore`/`build` the solution, then `docker compose -f .docker/compose.yaml --profile <dev|prod> build && push` to `ghcr.io/<repo>`. Branch decides the tag: `develop` → `dev-latest`, `main` → `prod-latest`.
2. **deploy-application.yaml** — runs on a self-hosted runner labelled `hoatheomua`. Pulls the image and `docker compose ... up -d` using the env-specific profile. `develop` deploys the `dev` environment, `main` deploys `prod`.
3. A Discord notification job reports build + deploy status.

Both environments run behind a **Cloudflare Tunnel** sidecar (`cloudflared`, see `compose.yaml`) for public ingress, so the gateway port need not be exposed publicly. The dev gateway also joins the external `hoatheomua-network-dev` network (owned by the backend's compose project) to reach `hoatheomua-api-dev:8080` — that network must already exist before `up`.

## Conventions

- The Docker build context is the **repo root** (`context: ..`), with the Dockerfile at `HoaTheoMua.ApiGateway/Dockerfile`. The container listens on `8080` (`ASPNETCORE_URLS=http://+:8080`).
- Branch model: `develop` = dev, `main` = prod. Pushing to either triggers a full build + deploy.
- When adding downstream services, change three places in lockstep: the `ReverseProxy` route+cluster config (or its `__` env-var equivalents in the compose files), the `.docker/.env.sample` address variables, and the deploy workflow secrets if a new backend address is needed.
