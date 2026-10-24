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
- Migrations live in `priv/repo/migrations/`. Tables: `organizations`, `stores`, `users`, `users_tokens`, `user_logins`, `categories`, `suppliers`, `products`, `product_stocks`, `sales`, `sale_items`, `cashier_shifts`, `cash_movements`, `service_products`, `service_transactions`, `deposit_accounts`, `deposit_entries`, `brand_prefixes`. (`products.stock` is a leftover column, no longer read; stock lives in `product_stocks`.)
- There is no CI workflow in the repo.

## Production / releases

- Built as an OTP release via `build.sh` (bare metal) or the multi-stage `Dockerfile`. Release-safe entry points in `lib/release.ex`: `Release.migrate`, `Release.seed`, `Release.rollback/2` — exposed as `bin/migrate`, `bin/seed`, `bin/server` overlays (`rel/overlays/bin/`).
- Prod config is runtime-driven (`config/runtime.exs`, only active when `config_env() == :prod`): requires `DATABASE_URL` and `SECRET_KEY_BASE`; optional `PHX_HOST`, `PORT`, `POOL_SIZE`, `UTC_OFFSET_HOURS`, `MAIL_FROM`, `FORCE_SSL` (behind a TLS proxy), `TRUSTED_PROXIES` (reverse proxies whose X-Forwarded-For is believed, for PPOB callbacks), `DATABASE_SSL`, `HTTPS_PORT` + `SSL_CERT_PATH` + `SSL_KEY_PATH` (HTTPS served by the app, for LAN use), and `SEED_*` vars for first accounts. Seeds never insert dev passwords or sample catalog in prod. Full guide: `docs/DEPLOYMENT.md`.
- No real mail adapter is configured: in prod `Zahlungs.Mailer.delivers?/0` is false, a warning is logged at boot and the login page hides "Forgot password?". Admins reset passwords and confirm users at `/admin/users`.

## Architecture

Standard Phoenix context layering — keep the boundary between the two. LiveViews and controllers call context functions only, never `Repo` or the schemas directly.

- `lib/zahlungs/` — **business/context layer** (no web concerns).
  - `stores.ex` — the branches. `scope.ex` — `%Zahlungs.Scope{user, store}`: who is acting and in which store (see Multi-store below).
  - `accounts.ex` — users, roles (`admin` / `cashier`), each cashier's store, activate/deactivate, admin password reset, session and email tokens, the login log.
  - `catalog.ex` — products (SKU, barcode, purchase price/margin, soft delete, consignment flag), categories, suppliers, stock report.
  - `sales.ex` — `create_sale/3`, `return_sale/2`, `void_sale/3`, sales history, and all reports including the consignment statement.
  - `shifts.ex` — open/close shift, cash movements, expected-cash reconciliation.
  - `services.ex` — PPOB services (Fase 0): service products and their price, service transactions, the service report. `deposits.ex` — deposit accounts, top-ups, corrections, estimated balance. See PPOB below.
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

### PPOB services (Fase 0, no provider API)

Spec: `docs/superpowers/specs/2026-10-16-layanan-ppob-fase-0-design.md`. The cashier does the top-up in the provider's own app; Zahlungs records it. Goods sales (`Sales`, `Catalog`, stock) are untouched.

- **Products** (`service_products`, owned): pulsa, paket data, token PLN at a fixed value; a bill (category `tagihan`: PLN, BPJS, PDAM, Telkom, PGN…) with the amount entered per sale. Price = cost + margin (rupiah, or percent rounded up to the rupiah); for a bill, cost = bill + provider fee and price = bill + admin fee (`Services.price_for/2`). Pulsa and paket data have a brand (`operator`, one of `Services.Brand.keys/0`, or nil = "Lainnya"); on the cashier screen the number is typed above the tiles and its prefix picks the brand (`Brand.detect/2`, a suggestion: by.U shares Telkomsel's prefixes), and SBI's catalog brings it (`Brand.from_sbi/2`). The prefixes are the platform operator's, one list for every organization (`brand_prefixes`, no `organization_id`; `/platform/brands`, `Services.brand_prefixes/0`, `save_brand_prefixes/1`: each `08xx`, one brand per prefix, all or nothing; `reset_brand_prefixes/0` puts back `Brand.default_prefixes/0`). The cashier screen reads them at mount. A number never shows another brand's products: a brand with none there shows the products without a brand ("Semua" shows all), and a selected product of another brand than the number's is flagged in the panel (a by.U product fits a Telkomsel number). Products made before brands got theirs from the name (migration `20261024120000`). Tests that write them are `async: false`.
- **Transactions** (`service_transactions`, per store like `sales`, no `organization_id`): `Services.record/3` on the cashier's open shift, in the shift's store, against that store's deposit account — none of them from params — with price and cost copied. Status `processing` → `success` (token/SN) or `failed` (reason; money handed back), final; `mark_success/3` / `mark_failed/3` lock the row, and only the recorder or an admin may mark.
- **Shift cash:** cash from `processing` and `success` services counts in `Shifts.expected_cash/1`; `close_shift/3` returns `{:error, :services_processing}` while any *manual* service of the shift is processing (`Services.count_blocking_close/1`); pending api services don't hold the shift.
- **Deposits** (`deposit_accounts`, `deposit_entries`, owned): each store picks one active account (`stores.deposit_account_id`); a store without one can't sell services. Estimated balance = top-ups + corrections − cost of `processing`/`success` services on the account. A top-up from the drawer is also a `deposit_topup` cash-out on the admin's open shift, in one transaction. `Deposits.reconcile/4` turns the difference with the provider's balance into a correction.
- Services are not in the sales report or the Home figures; they have `/reports/services`.

### PPOB Fase 1 (provider API)

Spec: `docs/superpowers/specs/2026-10-19-layanan-ppob-fase-1-design.md`. Per deposit account, `mode` is `manual` (Fase 0, above) or `api`: Zahlungs itself talks to the provider: Smart Biller Indonesia (`Provider.Sbi`, below) or, in dev/test only, `Services.Provider.Fake`.

- **Provider** (`services/provider.ex`): a behaviour (`credential_fields/0`, `inquiry/2`, `pay/2`, `status/2`, `verify_callback/3`, `ping/1`, optional `balance/1`); adapters are registered by key in `config :zahlungs, :provider_adapters` (default: the fake one; test adds `Provider.Broken` from `test/support`). Results are `%{status: :success | :failed | :pending, ...}`; a timeout or network error is *pending*, never failed. The fake answers by the number's last digit (see its moduledoc).
- **Credentials** are encrypted with a key derived from `secret_key_base` (`Deposits.Credentials`), write-only in the form (a blank field keeps what is stored), redacted on the schema. `Deposits.provider/1` gives `{:ok, adapter, credentials}` for api accounts; `Deposits.connection/1` does the same regardless of mode, for answering services sent before a switch to manual.
- **Bills on api:** `Services.inquire/3,4` asks the provider first (15 s, valid 15 min, `service_inquiries`); `record/3` takes `"inquiry_id"` and the bill, months (`sheets`), name and period from the inquiry — never from params. Admin fee and provider fee are per month. Other api products need a `provider_code`.
- **Sending:** an api service is recorded `processing` (`channel: "api"`), then sent after commit by `Services.Dispatcher` (`Task.Supervisor`; inline in test). `sent_at` is claimed under a row lock so a payment goes out once. `Services.apply_result/2` is the only way to a final status: it locks the row and changes only `processing` ones, so the dispatcher, the status checker and callbacks can race safely. Changes are broadcast on `"services:store:<id>"` (`Services.subscribe/1`).
- **Settling pending:** `Services.StatusChecker` (GenServer, every 60 s) runs `check_pending/1`: re-asks the provider 30 s after the last check (or after sending), sends unsent ones; a service that raises is logged and doesn't stop the round. Providers may also call `POST /api/ppob/callback/:token` (`PpobCallbackController`, token per account, signature checked by the adapter).
- **Failures are refunded by a person.** A failed api service waits under "Perlu dikembalikan" until the cashier confirms (`Services.confirm_refund/2`), and counts in its shift's cash until then (the money is still in the drawer). Refunded on its own shift, it leaves that drawer; refunded on any other shift (later, or a colleague's), it is a `refund` cash-out there and is flagged `failed_after_shift_close`, so it keeps counting in its own shift. `mark_success`/`mark_failed` return `{:error, :not_manual}` for api services, except for an admin once the service has waited 10 minutes (`Services.awaiting_too_long?/1`).
- **Test config:** `config :zahlungs, :service_dispatch, :inline` and `:service_status_checker, false` (`config/test.exs`); call `Services.check_pending/1` with a later time to settle in tests.

### PPOB through Smart Biller Indonesia (SBI)

Spec: `docs/superpowers/specs/2026-10-21-layanan-ppob-sbi-design.md`. SBI has no sandbox: the first real trial uses a small deposit (checklist in `docs/DEPLOYMENT.md`).

- **Adapter** `services/provider/sbi.ex` (key `"sbi"`; prod registers only this one): signed JSON (`Sbi.Sign`), answers read by `Sbi.Reply` (status 1/2/11, RC in `msg`, SN, actual cost), HTTP through `Sbi.Client` (`:httpc`, TLS verified, HTTPS only). Config `config :zahlungs, Zahlungs.Services.Provider.Sbi` (`base_url`, `client`, `callback_ips`, `pricelist_url`). Credentials: Member ID, PIN, Password. Rule: when in doubt (timeout, HTTP 5xx, not JSON, RC:94/08, unknown RC, any error on `status`) it is **pending**, never failed.
- **Tests never call SBI:** `config/test.exs` uses `Sbi.StubClient` (`test/support`): `expect(action, answer)` queues answers per test process (found through `$callers`), `respond(action, fun)` answers concurrent requests, `requests/0` lists what was sent. The catalog cache's `ttl` is 0 in tests.
- **Refs** (`Services.Ref`): `Z…` for an api transaction, `Q…` for an inquiry — store id + time + random, unique across organizations. A bill is paid with its inquiry's ref (SBI requires the same `ref_1`); a token PLN isn't.
- **Copies on the transaction:** `provider_code`, `quoted_cost` (cost when recorded), `cost` replaced by the vendor's `actual_cost`, `provider_payload` (raw answer, ≤ 4000 chars), `customer_details` (tariff/power). An actual cost above the product's cost sets the product's `provider_price` ("Modal SBI naik").
- **Prices on api:** a bill costs `provider_total` (bill + provider admin) + `api_extra_fee` × sheets (months); a token PLN whose product has `owner_check` (default true; false = bought directly like pulsa) needs a `"customer"` inquiry first (owner check with the product's `provider_check_code`, blank = the provider's default, `CPLNPRA` at SBI — not in every member's price plan). A product whose `provider_status` is set and not `normal` can't be sold through an api account.
- **Reviews:** an answer that contradicts a final status (refund after success, success after failure) only sets `review_reason`; an admin decides on the deposit account page (`Services.resolve_review/3`: `:refund` fails a success into "Perlu dikembalikan", `:success` makes an unrefunded failure a success, `:keep`); a failure in review is not refundable (`confirm_refund/2` → `:in_review`). A failure after success (any reason, not only RC:31) is held too.
- **Callbacks:** `POST /api/ppob/callback` (no token) → `Services.handle_ref_callback/2`: the adapter's `callback_ref/1` names the service (SBI `ref_1`), its account's adapter verifies (SBI: `rqid` header = password, and the caller's address in `callback_ips`). The caller's address is `ZahlungsWeb.ClientIp.of/2`: `X-Forwarded-For` only from `config :zahlungs, :trusted_proxies` (`TRUSTED_PROXIES` in prod), passed to adapters as header `"x-zahlungs-client-ip"`, always set by the controller.
- **Catalog:** `Services.search_catalog/2` (SBI's public price list, kept in `Services.CatalogCache` for 10 minutes, never stored) fills the product form; `Services.price_update/1` + `apply_price_update/2` refresh cost and status from the member's prices (`/api/price`).
- **Tagihan (postpaid bills):** one category `tagihan` ("Tagihan") for every bill, told apart by product (name, vendor code); it replaced `tagihan_pln` (migration `20261023100000`, reversible), and the SBI catalog hints every item of SBI group "PPOB" as `tagihan`. `service_products.ask_months` ("Tanyakan jumlah bulan saat cek tagihan", bills only): on an api account the cashier picks "Jumlah bulan" 1-12 before Cek tagihan; `Services.inquire(user, product_id, customer_ref, opts)` takes `months:` (nil/"" → 1; outside 1-12 → `{:error, :invalid_months}` before the provider is called), stored on `service_inquiries.months`; changing it after the check drops the check on screen. SBI gets `"periode"` (months as a string) on `inquiry` and `payment` only, never `topup`/`status`, outside `sign`. The inquiry's `sheets` (shown "N bulan") = the provider's month count (`Jml bulan:`), else the months asked, else 1. Manual accounts: amount typed, no months.

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
- **Money:** `Decimal` everywhere, displayed with `format_money/1` (`format_price/1` drops zero cents, on the Layanan screen).
- `config :zahlungs, :env, Mix.env()` is set in `config.exs`; the router uses it at compile time to mount `/dashboard` (LiveDashboard) and `/dev/mailbox` in dev/test only.
- Test support in `test/support/`: `conn_case`, `data_case`, fixtures for stores, accounts, catalog and shifts, and `live_driver.ex`. Each test gets its own default store (`StoresFixtures.default_store/0`); `user_fixture/1` and `product_fixture/1` use it, `scope(user)` / `store_scope()` build scopes, `stock_of(product)` reads stock, and `user_on_shift_fixture/0` gives a user who can record sales.
- **LiveView tests** can't use `Phoenix.LiveViewTest.live/2` yet — it needs the `lazy_html` package, which isn't installed. Access control is tested with `get/2`; behaviour is tested by driving the LiveView's callbacks through `ZahlungsWeb.LiveDriver` (`mount_live/3`, `event/3`, `html/1`). Events sent with `JS.push(value: ...)` arrive as JSON numbers, so handlers must accept both integers and strings for ids and pages.
- Line endings are LF, enforced by `.gitattributes`.
