# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`Zahlungs` is a Phoenix 1.6 web app (Elixir `~> 1.12`) with LiveView. It is essentially a `phx.gen.auth`–generated authentication scaffold — registration, login, email confirmation, password reset, and user settings — on top of a single LiveView landing page (`/`). There is no domain/business logic beyond accounts yet.

## Commands

```bash
mix setup              # deps.get + ecto.setup (create, migrate, seed)
mix ecto.setup         # ecto.create + ecto.migrate + run priv/repo/seeds.exs
mix ecto.reset         # drop + setup
mix phx.server         # run dev server at localhost:4000 (iex -S mix phx.server for a shell)
mix test               # auto-runs ecto.create --quiet + ecto.migrate --quiet first (see aliases)
mix test test/path/to/file_test.exs            # single file
mix test test/path/to/file_test.exs:42         # single test by line number
mix format             # uses .formatter.exs (imports :ecto and :phoenix)
mix credo              # static analysis (dev/test only)
mix sobelow            # security-focused static analysis (dev only)
mix assets.deploy      # tailwind --minify + esbuild --minify + phx.digest (prod assets)
```

JS/CSS assets live in `assets/` and are built by the `esbuild`/`tailwind` mix wrappers (no separate npm build step needed in dev — `phoenix_live_reload` handles dev). `npm install` inside `assets/` is only required per the README for raw node deps.

## Database

- Dev/test use **MySQL/MariaDB** via `myxql`. Credentials come from env vars (`DB_HOST`, `DB_PORT`, `DB_USERNAME`, `DB_PASSWORD`, `DB_NAME`/`DB_TEST_NAME`, with localhost defaults) and/or the gitignored `config/local.secret.exs`. CI (`.github/workflows/ci.yml`) runs the suite against a MySQL 8 service container.
- Migrations live in `priv/repo/migrations/`. The only schema so far is the auth tables (`users`, `users_tokens`).

## Production / releases

- Built as an OTP release via `build.sh` (bare metal) or the multi-stage `Dockerfile`. Release-safe entry points in `lib/release.ex`: `Release.migrate`, `Release.seed`, `Release.rollback/2` — exposed as `bin/migrate`, `bin/seed`, `bin/server` overlays (`rel/overlays/bin/`).
- Prod config is runtime-driven (`config/runtime.exs`, only active when `config_env() == :prod`): requires `DATABASE_URL` and `SECRET_KEY_BASE`; optional `PHX_HOST`, `PORT`, `POOL_SIZE`, `FORCE_SSL` (behind a TLS proxy), `DATABASE_SSL`, and `SEED_*` vars for first accounts. Seeds never insert dev passwords or sample catalog in prod. Full guide: `docs/DEPLOYMENT.md`.

## Architecture

Standard Phoenix context layering — keep the boundary between the two:

- `lib/zahlungs/` — **business/context layer** (no web concerns).
  - `accounts.ex` is the public API for everything user-related; controllers and tests call only these functions, never the schemas directly. The schemas (`accounts/user.ex`, `accounts/user_token.ex`) and `accounts/user_notifier.ex` are internal to the context.
  - `repo.ex`, `mailer.ex` (Swoosh, `Local` adapter in dev), `application.ex` (supervision tree: Repo → Telemetry → PubSub → Endpoint).
- `lib/zahlungs_web/` — **web layer**. Controllers + views + heex templates (traditional MVC style here, not LiveView, except `live/page_live.ex`). Routing in `router.ex`.

### Auth flow (the core of this app)

- `ZahlungsWeb.UserAuth` (`controllers/user_auth.ex`) holds the auth plugs imported into the router: `fetch_current_user`, `require_authenticated_user`, `redirect_if_user_is_authenticated`, plus session login/logout helpers (token-based sessions, remember-me cookie).
- Routes are grouped in `router.ex` by auth requirement — three separate `scope "/"` blocks pipe through different combinations of these plugs. Add new authenticated routes to the `:require_authenticated_user` scope.
- Tokens (session, email confirmation, reset, email change) are all hashed and persisted via `UserToken` / the `users_tokens` table; `Accounts` exposes the `deliver_*` and `*_token` functions that drive them.
- Passwords hashed with `pbkdf2_elixir`.

### Conventions

- `config :zahlungs, :env, Mix.env()` is set in `config.exs` and read at runtime (e.g. router gates `live_dashboard "/dashboard"` to dev/test via `Application.get_env(:zahlungs, :env)`).
- Test support in `test/support/` (`conn_case`, `data_case`, `channel_case`, `fixtures/accounts_fixtures.ex`). Tests run against a real MySQL test DB inside the Ecto SQL sandbox.
- `.projections.json` defines vim/editor alternate-file mappings (source ↔ test) if useful for navigation.
