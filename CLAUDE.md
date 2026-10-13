# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`Zahlungs` is a point-of-sale (POS) web app for a shop with one or more branches (one owner, one central server): Phoenix 1.8 + LiveView 1.2 on Elixir `~> 1.14`, MySQL/MariaDB via `myxql`. Cashiers open a shift, sell from a cart (barcode scan or search), and close the shift with a cash reconciliation; admins manage products, categories, suppliers and users, and read the sales, stock and consignment reports. UI text is a mix of Indonesian and English.

Product docs live in `docs/` (Indonesian): `PRD-POS.md`, `IA.md` (sitemap + who can see what), `CONCEPT-cashier-shift.md`, the `SPRINT-*.md` plans, and `DEPLOYMENT.md`.

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
mix deps.audit         # dependency vulnerability scan (mix_audit)
mix assets.deploy      # tailwind --minify + esbuild --minify + phx.digest (prod assets)
```

JS/CSS assets live in `assets/` and are built by the `esbuild`/`tailwind` mix wrappers (no separate npm build step in dev). `assets/js/app.js` holds the LiveView hooks (barcode camera, beeper, money/currency inputs).

## Database

- Dev/test use **MySQL/MariaDB** via `myxql`. Credentials come from env vars (`DB_HOST`, `DB_PORT`, `DB_USERNAME`, `DB_PASSWORD`, `DB_NAME`/`DB_TEST_NAME`, with localhost defaults) and/or the gitignored `config/local.secret.exs`.
- `mix test` runs pending migrations against whatever database the test config points at. If dev and test share one database, tests still clean up after themselves (SQL sandbox), but rows that already exist are visible to them: look fixtures up by a unique name/SKU rather than expecting them first in a list, and don't assert that a table is empty.
- Migrations live in `priv/repo/migrations/`. Tables: `organizations`, `stores`, `users`, `users_tokens`, `user_logins`, `categories`, `suppliers`, `products`, `product_stocks`, `sales`, `sale_items`, `cashier_shifts`, `cash_movements`. (`products.stock` is a leftover column, no longer read; stock lives in `product_stocks`.)
- There is no CI workflow in the repo.

## Production / releases

- Built as an OTP release via `build.sh` (bare metal) or the multi-stage `Dockerfile`. Release-safe entry points in `lib/release.ex`: `Release.migrate`, `Release.seed`, `Release.rollback/2` — exposed as `bin/migrate`, `bin/seed`, `bin/server` overlays (`rel/overlays/bin/`).
- Prod config is runtime-driven (`config/runtime.exs`, only active when `config_env() == :prod`): requires `DATABASE_URL` and `SECRET_KEY_BASE`; optional `PHX_HOST`, `PORT`, `POOL_SIZE`, `UTC_OFFSET_HOURS`, `MAIL_FROM`, `FORCE_SSL` (behind a TLS proxy), `DATABASE_SSL`, `HTTPS_PORT` + `SSL_CERT_PATH` + `SSL_KEY_PATH` (HTTPS served by the app, for LAN use), and `SEED_*` vars for first accounts. Seeds never insert dev passwords or sample catalog in prod. Full guide: `docs/DEPLOYMENT.md`.
- No real mail adapter is configured: in prod `Zahlungs.Mailer.delivers?/0` is false, a warning is logged at boot and the login page hides "Forgot password?". Admins reset passwords and confirm users at `/admin/users`.

## Architecture

Standard Phoenix context layering — keep the boundary between the two. LiveViews and controllers call context functions only, never `Repo` or the schemas directly.

- `lib/zahlungs/` — **business/context layer** (no web concerns).
  - `stores.ex` — the branches. `scope.ex` — `%Zahlungs.Scope{user, store}`: who is acting and in which store (see Multi-store below).
  - `accounts.ex` — users, roles (`admin` / `cashier`), each cashier's store, activate/deactivate, admin password reset, session and email tokens, the login log.
  - `catalog.ex` — products (SKU, barcode, purchase price/margin, soft delete, consignment flag), categories, suppliers, stock report.
  - `sales.ex` — `create_sale/3`, `return_sale/2`, `void_sale/3`, sales history, and all reports including the consignment statement.
  - `shifts.ex` — open/close shift, cash movements, expected-cash reconciliation.
  - `local_time.ex` — shop-local time (see Conventions).
  - `repo.ex`, `mailer.ex` (Swoosh), `application.ex` (supervision tree: Repo → Telemetry → PubSub → Endpoint).
- `lib/zahlungs_web/` — **web layer**. The POS screens are LiveViews in `live/` (`cashier_live.ex` is the main one); auth pages, user settings and the printable receipt are plain controllers + heex templates in `controllers/`. Shared function components are in `components/core_components.ex`; create/edit forms are live components (`*/form_component.ex`).

### Auth and roles

- `ZahlungsWeb.UserAuth` (`controllers/user_auth.ex`) holds the auth plugs and the matching LiveView `on_mount` hooks: `fetch_current_user`, `require_authenticated_user` / `:ensure_authenticated`, `require_admin_user` / `:ensure_admin`, `redirect_if_user_is_authenticated`.
- `router.ex` groups routes by requirement: guest-only auth pages, an authenticated `live_session` (home, catalog, cashier, sales, shifts), and an admin-only `live_session` (products, categories, users, suppliers, reports). Put a new route in the scope that matches who may see it; the plug and the `on_mount` hook must both apply.
- A business signs up publicly at `/signup` (see Multi-tenant); within an organization, admins create accounts at `/admin/users`. `Accounts.register_user/1` remains for seeds and test fixtures. A new user's role is never taken from user input.
- Event handlers re-check the role for sensitive actions (return, void) — hiding a button is not authorization.
- Tokens (session, email confirmation, reset, email change) are hashed and stored in `users_tokens`. Passwords are hashed with `pbkdf2_elixir`.

### Multi-tenant (SaaS)

Several owners share one database; full notes in `docs/SAAS-multi-pemilik.md`.

- **Organization = tenant** (`organizations`, status `pending` / `active` / `suspended` / `rejected`). Owned tables carry `organization_id`: `stores`, `users`, `categories`, `suppliers`, `products`, `user_logins`. Per-store tables (stock, shifts, cash movements, sales) have none: they belong to a store, which belongs to an organization.
- **`Zahlungs.Repo` is the guard.** Any query whose root schema has `organization_id` is filtered to the process's current organization, and raises when there is none. The current organization is set by `Repo.put_org_id/1`, which `Scope.for_user/2` and `Scope.for_store/1` call — so building a scope enters that user's organization. Pass `skip_org_id: true` only for queries that must cross organizations (user lookup by email before login, the platform pages, maintenance). The guard checks the root table only: don't rely on it for joins or subqueries.
- **New owned rows** get their organization from `Organizations.put_organization/1` in the schema's changeset; users from `Repo.get_org_id/0` in `Accounts`.
- **"All stores"** means every store of the admin's organization (`Stores.store_ids/0`), never an unfiltered query — sales and shifts are shared tables.
- **Uniqueness is per organization** for SKU, barcode, category name and store code (invoice codes per store). Email is unique across all organizations (`unsafe_validate_unique(..., repo_opts: [skip_org_id: true])`).
- **Roles:** `superadmin` (platform operator: no organization, only `/platform`, created by seeds via `Accounts.create_platform_admin/1`), `admin` (an organization's owner/staff), `cashier`. `Scope.block_reason/1` says why a scope can't use the app (`:pending`, `:rejected`, `:suspended`, `:no_store`, `:no_organization`); the login controller and `UserAuth` act on it.
- **Sign-up** (`/signup`, public, rate-limited) creates a pending organization, a first store and the owner via `Organizations.register/1`; the operator reviews at `/platform/organizations`. Billing is a manual record (`paid_until`, `billing_note`). Sign-ups and status changes are broadcast (`Organizations.subscribe/0` → `{:organizations_changed, id}`); the operator's page listens, so its pending count stays current.
- **Tests** start inside a default organization (`DataCase`, `StoresFixtures.default_org/0`); use `organization_fixture/1` + `in_org/2` for a second one.

### Multi-store

- **Shared:** users, categories, suppliers, products (name, SKU, barcode, prices). **Per store:** stock (`product_stocks`), shifts, cash movements, sales.
- **Scope.** `UserAuth` builds a `Zahlungs.Scope` per request / LiveView mount (`@current_scope`). A cashier's store is their own; an admin's is the one picked in the navbar switcher (session `:store_id`), or `nil` for "all stores". Context functions that read or write per-store data take the scope as their first argument and filter with `Scope.store_id/1`, which raises for a non-admin without a store — never accept a `store_id` from params.
- **Fetching another store's row raises** `Ecto.NoResultsError` (`Sales.get_sale!/2`, `Shifts.get_shift!/2`), i.e. a 404.
- **A sale's store is its shift's store**, and the shift's comes from the scope at `Shifts.open_shift/2`. `create_sale/3` takes stock from that store; `return_sale`/`void_sale` put it back there, not in the store of whoever processes them. The cashier screen reads stock with the open shift's store (`@sale_scope`), which can differ from the navbar choice.
- **"All stores"** (admin, `scope.store == nil`): lists and reports are unfiltered, product `stock` is the sum over stores, and opening a shift or setting stock is refused.
- **Product `stock` is a virtual field** filled from the scope's store by `Catalog` (`list_products/2`, `get_product!/2`, …); a product loaded any other way has `stock: 0`.
- **Time zone is per store** (`stores.utc_offset_hours`): pass the store to `Zahlungs.LocalTime` functions; without one the default offset applies.
- **Login:** `ZahlungsWeb.LoginThrottle` refuses logins after repeated failures; `Accounts.record_login/3` logs each successful login with the browser's position (audit only — never used to refuse a login). A cashier without an active store is not let in.

### Invariants worth knowing before changing sales or shifts

- **A sale needs an open shift.** `Sales.create_sale/3` looks up and row-locks the cashier's open shift itself; it ignores any `shift_id` from the caller and returns `{:error, :no_open_shift}` otherwise.
- **Stock can't be oversold.** Stock is decremented with a guarded `UPDATE ... WHERE stock >= qty` inside the sale's transaction.
- **Sale items are snapshots.** Unit price, purchase price, and the consignment flag + supplier are copied onto `sale_items` at sale time; reports read the snapshot, not the product.
- **State changes re-check under a row lock.** `return_sale`, `void_sale`, `close_shift`, `add_cash_movement` and `open_shift` lock the row (`FOR UPDATE`) and trust the database, not the struct they were handed — a LiveView in another tab may hold a stale one.
- **A closed shift's figures are final.** A sale returned or voided after its shift closed is flagged `adjusted_after_shift_close` and still counts toward that shift; a cash refund is booked as a `refund` cash-out on the refunder's open shift.
- **Amounts are validated in the context.** Discount must be between 0 and the subtotal, tax can't be negative; the cashier screen mirrors the rule but the context enforces it.

### Conventions

- **Time:** timestamps are stored in UTC; anything about "today", a date range, or a time shown to a person goes through `Zahlungs.LocalTime` (fixed offset, `config :zahlungs, :utc_offset_hours`, default 7 = WIB). Don't use `Date.utc_today/0` for business dates.
- **Money:** `Decimal` everywhere, displayed with `format_money/1`.
- `config :zahlungs, :env, Mix.env()` is set in `config.exs`; the router uses it at compile time to mount `/dashboard` (LiveDashboard) and `/dev/mailbox` in dev/test only.
- Test support in `test/support/`: `conn_case`, `data_case`, fixtures for stores, accounts, catalog and shifts, and `live_driver.ex`. Each test gets its own default store (`StoresFixtures.default_store/0`); `user_fixture/1` and `product_fixture/1` use it, `scope(user)` / `store_scope()` build scopes, `stock_of(product)` reads stock, and `user_on_shift_fixture/0` gives a user who can record sales.
- **LiveView tests** can't use `Phoenix.LiveViewTest.live/2` yet — it needs the `lazy_html` package, which isn't installed. Access control is tested with `get/2`; behaviour is tested by driving the LiveView's callbacks through `ZahlungsWeb.LiveDriver` (`mount_live/3`, `event/3`, `html/1`). Events sent with `JS.push(value: ...)` arrive as JSON numbers, so handlers must accept both integers and strings for ids and pages.
- Line endings are LF, enforced by `.gitattributes`.
