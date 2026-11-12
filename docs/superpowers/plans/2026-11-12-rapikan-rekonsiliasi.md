# Rapikan Rekonsiliasi Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the reconciliation page and the correction popup show danger, differences and the one right action at a glance.

**Architecture:** Web layer only. `ZahlungsWeb.ServiceCorrection.popup/1` gets a footer with Batal + a verb button and a warning for both directions. `DepositLive.Reconcile` replaces `@kind_labels`/`@buttons` with one kind map (label, tone, hint, primary button), orders rows and chips by it, highlights differences, and turns the chips into a filter that replaces "Lihat yang cocok".

**Tech Stack:** Phoenix LiveView 1.2, HEEx, Tailwind; tests through `ZahlungsWeb.LiveDriver`.

**Spec:** `docs/superpowers/specs/2026-11-12-rapikan-rekonsiliasi-design.md`

## Global Constraints

- No change to contexts (`Services`, `Services.Reconciliation`), schemas, migrations, or what is asked of SBI.
- UI text in Indonesian, exactly as the spec writes it; code, comments, commits in English.
- Tests use made-up values only; SBI is `Sbi.StubClient`.
- Kind text from an event is matched against the kind map, never `String.to_atom`/`String.to_existing_atom`.
- Commit format `type(rapikan-rekonsiliasi): subject`, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- `.claude/launch.json` stays untracked.

## Review Focus

1. A recheck or correction that moves a row out of the active filter: the row leaves the view, the filter stays, the chip counts update — Task 3 test "a filter stays after a button".
2. Row indexes after reordering: buttons on a reordered row still act on that row (`phx-value-index` is the index in `@rows`, not the display position) — Task 2 test "buttons keep their row after reordering".
3. Refund at SBI vs Gagal at Zahlungs is not a difference — Task 2 test of `same_status?/2`.
4. A negative cost difference is written "selisih −Rp …" (U+2212), not "Rp -…" — Task 2 test of `cost_note/1`.
5. The popup over a transaction that is neither success nor failed never renders (the button isn't offered), so the verb button only needs the two directions — covered by existing `button?` tests; no new test.

---

### Task 1: The correction popup and the Gagal badge

**Files:**
- Modify: `lib/zahlungs_web/components/service_correction.ex` (`popup/1`, `status_label/1`, new `status_badge/1`)
- Modify: `lib/zahlungs_web/live/service_live/history.ex` (`status_badge/1`, failed colour)
- Modify: `CLAUDE.md` (PPOB Fase 1 → "Admin correction" bullet), `docs/superpowers/specs/2026-11-12-koreksi-layanan-design.md` (Popup section)
- Test: `test/zahlungs_web/live/service_history_live_test.exs` (describe "correcting a status")
- Also commit: the spec and this plan.

**Interfaces:**
- Consumes: `ServiceCorrection.target/1` (`"failed" | "success"`), existing events `cancel_correction`, `confirm_correction`.
- Produces: nothing new for later tasks (Task 2 reuses the popup as is).

- [ ] **Step 1: Write the failing tests** in describe "correcting a status" (`corrected/3`, `status_of/1` exist there):

```elixir
defp popup_html(ctx, tx),
  do: ServiceLive.History |> mount_live(ctx.admin) |> event("review_correction", %{"id" => tx.id}) |> html()

test "the popup names its action", ctx do
  html = popup_html(ctx, ctx.success)
  assert html =~ ~r/<button[^>]*!bg-red-600[^>]*>\s*Jadikan gagal\s*<\/button>/
  refute html =~ "Simpan koreksi"
end

test "towards success warns the money stays", ctx do
  {:ok, failed} = Services.correct_status(ctx.admin, ctx.success, "failed", "Uji")
  html = popup_html(ctx, failed)
  assert html =~ "tidak jadi dikembalikan ke pelanggan; transaksi dihitung berhasil."
  assert html =~ ~r/<button[^>]*>\s*Jadikan berhasil\s*<\/button>/
end

test "Batal sits at the bottom, before the main button", ctx do
  html = popup_html(ctx, ctx.success)
  assert html =~ ~r/<\/textarea>.*phx-click="cancel_correction".*Jadikan gagal/s
  refute html =~ ~r/<\/h3>\s*<button[^>]*cancel_correction/
end

test "a failed service has a red badge", ctx do
  {:ok, _} = Services.correct_status(ctx.admin, ctx.success, "failed", "Uji")
  html = ServiceLive.History |> mount_live(ctx.admin) |> html()
  assert html =~ ~r/bg-red-100 text-red-700[^>]*>\s*Gagal/
end
```

- [ ] **Step 2: Run them, watch them fail**

Run: `mix test test/zahlungs_web/live/service_history_live_test.exs`
Expected: the four new tests FAIL (no "Jadikan gagal" button text, no warning, Batal in the header, grey badge); the rest pass.

- [ ] **Step 3: Implement**
  - Header: only the `<h3>`, keeping `pr-10` on its wrapper (the existing "Batal doesn't sit under the popup's close mark" test still matches `pr-10">\s*<h3`).
  - Status row: `status_badge` "now → target" with classes success `bg-green-100 text-green-700`, failed `bg-red-100 text-red-700`, processing `bg-amber-100 text-amber-800` (pill: `inline-block rounded-full px-2 py-0.5 text-xs`).
  - Warning box (same amber box) for both directions; success text: "Uang {format_price(price)} tidak jadi dikembalikan ke pelanggan; transaksi dihitung berhasil."
  - Footer inside the form, `mt-4 flex justify-end gap-2`: `<button type="button" phx-click="cancel_correction" class="chip">Batal</button>`, then `<.button phx-disable-with="Menyimpan...">` with "Jadikan gagal" + `class="!bg-red-600"` or "Jadikan berhasil".
  - Update the `popup/1` doc: focus goes to the first field (the modal's `JS.focus_first`).
  - History `status_badge/1`: failed → `bg-red-100 text-red-700`.
  - Docs: CLAUDE.md "Admin correction" bullet — the popup focuses its first field, buttons "Jadikan gagal"/"Jadikan berhasil"; koreksi spec Popup section — a note that focus and buttons are replaced by `2026-11-12-rapikan-rekonsiliasi-design.md`.

- [ ] **Step 4: Run, watch them pass**

Run: `mix test test/zahlungs_web/live/service_history_live_test.exs test/zahlungs_web/live/deposit_live/reconcile_test.exs`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/zahlungs_web/components/service_correction.ex lib/zahlungs_web/live/service_live/history.ex test/zahlungs_web/live/service_history_live_test.exs CLAUDE.md docs/superpowers/specs/2026-11-12-koreksi-layanan-design.md docs/superpowers/specs/2026-11-12-rapikan-rekonsiliasi-design.md docs/superpowers/plans/2026-11-12-rapikan-rekonsiliasi.md
git commit -m "feat(rapikan-rekonsiliasi): a correction popup that names its action"
```

### Task 2: Kind map, order, hints, differences and buttons on the reconciliation rows

**Files:**
- Modify: `lib/zahlungs_web/live/deposit_live/reconcile.ex`
- Test: `test/zahlungs_web/live/deposit_live/reconcile_test.exs`

**Interfaces:**
- Consumes: rows from `Services.reconcile/3,4` (`%{kind, ref, ours, theirs, in_review?}`), `ServiceCorrection.button?/2`.
- Produces (Task 3 relies on these):
  - `@kinds_ui` — ordered keyword list/list of `{kind, %{label, tone, hint, button}}` in the spec's order `[:conflict, :theirs_only, :follow, :ours_only, :pending_there, :cost_diff, :matched]`; `tone` is `:red | :amber | :green`; `button` is `"Ikuti SBI" | "Cek status" | nil` (`:conflict` handled specially).
  - `defp tone_classes(tone)` → the spec's chip/badge classes (`border-red-300 bg-red-50 text-red-800`, amber, green).
  - `@doc false def same_status?(ours, theirs)` → boolean (nil on either side → false; success=success, failed=failed or refunded, processing=pending).
  - `@doc false def cost_note(row)` → `nil | "selisih +Rp 150" | "selisih −Rp 150"` (theirs.cost − ours.cost; nil when a side has no cost or they're equal).
  - Display order: `@indexed` sorted by the kind's position in `@kinds_ui`, stable, each row keeping its index in `@rows`.

- [ ] **Step 1: Write the failing tests** (new describe "rows"; add an optional cost to `sbi_row/2` → `sbi_row(ref, status, cost \\ "5150")`):

```elixir
test "a dangerous row comes first", ctx do
  follow = service!(ctx, status: "processing")
  conflict = service!(ctx, status: "success")
  StubClient.expect("history", page([sbi_row(follow.ref_id, 1), sbi_row(conflict.ref_id, 11)]))
  html = ctx |> open() |> reconcile() |> html()
  # "<" ends the code, so LYT-5 never matches inside LYT-56
  {c, _} = :binary.match(html, conflict.code <> "<")
  {f, _} = :binary.match(html, follow.code <> "<")
  assert c < f
end

test "buttons keep their row after reordering", ctx do
  # same setup; Koreksi status of the conflict row opens that row's transaction
  socket = ...
  conflict_index = Enum.find_index(socket.assigns.rows, &(&1.kind == :conflict))
  assert event(socket, "review_correction", %{"index" => conflict_index}).assigns.correcting.transaction.id == conflict.id
  assert html(socket) =~ ~r/phx-value-index="#{conflict_index}"[^>]*>\s*Koreksi status/
end

test "labels and hints", ctx do
  # one :follow row
  assert html =~ "Belum final di Zahlungs"
  assert html =~ "SBI sudah final, Zahlungs masih Diproses."
  assert html =~ ~r/<button[^>]*phx-click="recheck"[^>]*>\s*Ikuti SBI/
end

test "a conflict: Koreksi status first, Cek status SBI second", ctx do
  html = ... # conflict row
  assert html =~ ~r/>\s*Koreksi status\s*<.*>\s*Cek status SBI\s*</s
  refute html =~ "Tinjau"
  assert html =~ "Zahlungs dan SBI sama-sama final tapi berbeda."
end

test "a row only at SBI has no button", ctx do
  StubClient.expect("history", page([sbi_row("ZUNKNOWN1", 1)]))
  html = ctx |> open() |> reconcile() |> html()
  assert html =~ "SBI memotong saldo, tapi transaksinya tidak ada di akun ini. Tanyakan ke SBI."
  refute html =~ ~r/phx-click="recheck"/
end

test "a cost difference is written out", ctx do
  s = service!(ctx, status: "success")
  StubClient.expect("history", page([sbi_row(s.ref_id, 1, "5300")]))
  assert ctx |> open() |> reconcile() |> html() =~ "selisih +Rp 150"
end

test "same_status?/2" do
  t = &%Transaction{status: &1}
  assert DepositLive.Reconcile.same_status?(t.("failed"), %{status: :refunded})
  assert DepositLive.Reconcile.same_status?(t.("processing"), %{status: :pending})
  refute DepositLive.Reconcile.same_status?(t.("success"), %{status: :failed})
  refute DepositLive.Reconcile.same_status?(t.("success"), nil)
  refute DepositLive.Reconcile.same_status?(nil, %{status: :success})
end

test "cost_note/1" do
  row = fn ours, theirs -> %{ours: ours && %{cost: Decimal.new(ours)}, theirs: theirs && %{cost: Decimal.new(theirs)}} end
  assert DepositLive.Reconcile.cost_note(row.(5150, 5300)) == "selisih +Rp 150"
  assert DepositLive.Reconcile.cost_note(row.(5300, 5150)) == "selisih −Rp 150"
  assert DepositLive.Reconcile.cost_note(row.(5150, 5150)) == nil
  assert DepositLive.Reconcile.cost_note(row.(5150, nil)) == nil
end

test "a different status is highlighted", ctx do
  # conflict row
  assert html =~ ~r/font-semibold text-red-700[^>]*>\s*Berhasil/
  assert html =~ ~r/font-semibold text-red-700[^>]*>\s*Gagal/
end
```

Fill the `...` with the setup each test names (as in the existing helpers `service!/2`, `sbi_row`, `page/1`, `open/1`, `reconcile/1`).

- [ ] **Step 2: Run them, watch them fail**

Run: `mix test test/zahlungs_web/live/deposit_live/reconcile_test.exs`
Expected: the new tests FAIL (undefined `same_status?/2`/`cost_note/1`, old order, old labels, "Tinjau"); existing tests pass.

- [ ] **Step 3: Implement** per the spec's section 1 "Golongan" and "Kartu baris": the kind map replaces `@kind_labels` and `@buttons`; the card gets `border-l-4` in the tone's colour, a tone badge, the hint (`text-sm`, none for `:matched`), status cells `font-semibold text-red-700` when `not same_status?`, the `cost_note` under Potongan SBI in `text-red-700`; buttons: a primary `.button` then secondary `chip`s, shown only when `row.ours && not row.in_review?` (as now). For `:conflict`: primary "Koreksi status" when `ServiceCorrection.button?`, then chip "Cek status SBI" (`recheck`); when correction isn't possible, only the chip. Other kinds: primary = the map's button (`recheck`), then chip "Koreksi status" when `button?`. Chips in the summary take the tone classes but stay non-clickable spans in this task.

- [ ] **Step 4: Run, watch them pass**

Run: `mix test test/zahlungs_web/live/deposit_live/reconcile_test.exs test/zahlungs_web/live/service_history_live_test.exs`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/zahlungs_web/live/deposit_live/reconcile.ex test/zahlungs_web/live/deposit_live/reconcile_test.exs
git commit -m "feat(rapikan-rekonsiliasi): rows that show danger, differences and one action"
```

### Task 3: Chips as a filter

**Files:**
- Modify: `lib/zahlungs_web/live/deposit_live/reconcile.ex` (assign `kind_filter`, event `filter_kind`; remove `show_matched`, `toggle_matched`)
- Modify: `CLAUDE.md` (Reconciliation bullet), `docs/IA.md` (Rekonsiliasi lines ~408-411)
- Test: `test/zahlungs_web/live/deposit_live/reconcile_test.exs`

**Interfaces:**
- Consumes: `@kinds_ui`, `tone_classes/1` from Task 2.
- Produces: event `"filter_kind"` with `%{"kind" => text}`; assign `kind_filter :: atom | nil`. Chip markup: `<button type="button" phx-click="filter_kind" phx-value-kind={kind} disabled={count == 0} aria-pressed={to_string(active?)} class=...>{label} <strong>{count}</strong></button>`; zero → `opacity-50`, active → `ring-2`.

- [ ] **Step 1: Write the failing tests** (new describe "filter"), and update the existing ones:
  - "reconciling shows the summary…": replace `"Lihat yang cocok (1)"` with `~r/phx-value-kind="matched"[^>]*>\s*Cocok\s*<strong>1<\/strong>/`, and `event("toggle_matched")` with `event("filter_kind", %{"kind" => "matched"})`; drop the "Sembunyikan yang cocok" assertion.
  - `followed/2` and "a conflict corrected to match SBI": same replacement for `"Lihat yang cocok (1)"`.
  - "the page" test "opening the page doesn't ask SBI": `refute html =~ "filter_kind"` instead of "Lihat yang cocok".

```elixir
test "a chip filters, a second click shows all again", ctx do
  follow = service!(ctx, status: "processing")
  conflict = service!(ctx, status: "success")
  StubClient.expect("history", page([sbi_row(follow.ref_id, 1), sbi_row(conflict.ref_id, 11)]))
  socket = ctx |> open() |> reconcile() |> event("filter_kind", %{"kind" => "conflict"})
  assert html(socket) =~ conflict.code
  refute html(socket) =~ follow.code
  assert html(socket) =~ ~r/aria-pressed="true"[^>]*>\s*Bertentangan/
  socket = event(socket, "filter_kind", %{"kind" => "conflict"})
  assert html(socket) =~ follow.code
end

test "a chip of nothing, or an unknown kind, changes nothing", ctx do
  # one :follow row; theirs_only has 0
  assert html =~ ~r/phx-value-kind="theirs_only"[^>]*disabled/
  for kind <- ["theirs_only", "nope", 1] do
    assert event(socket, "filter_kind", %{"kind" => kind}).assigns.kind_filter == nil
  end
end

test "Cocokkan again shows all", ctx do
  # one :follow row, filter "follow", then reconcile again (second expect)
  assert socket.assigns.kind_filter == nil
end

test "everything matched", ctx do
  s = service!(ctx, status: "success")
  StubClient.expect("history", page([sbi_row(s.ref_id, 1)]))
  html = ctx |> open() |> reconcile() |> html()
  assert html =~ "Semua transaksi cocok dengan SBI."
  refute html =~ s.code
end

test "a filter stays after a button", ctx do
  # one :follow row, filter "follow", recheck answers success (as in followed/2)
  assert socket.assigns.kind_filter == :follow
  refute html(socket) =~ follow.code
  assert html(socket) =~ ~r/phx-value-kind="matched"[^>]*>\s*Cocok\s*<strong>1<\/strong>/
end
```

- [ ] **Step 2: Run them, watch them fail**

Run: `mix test test/zahlungs_web/live/deposit_live/reconcile_test.exs`
Expected: the new and updated tests FAIL (no `filter_kind`, no `kind_filter`).

- [ ] **Step 3: Implement** per the spec's "Chip ringkasan menjadi filter": `kind_filter` starts `nil` at mount and on every `reconcile`; `filter_kind` accepts only a kind whose `to_string` is a key of `@kinds_ui` and whose count > 0, toggling it off when already active; `nil` shows every row but `:matched`, a kind shows only its rows; "Semua transaksi cocok dengan SBI." when `nil`, `rows != []` and no row needs action. Remove the "Lihat yang cocok" block, `show_matched` and `toggle_matched`. Docs: CLAUDE.md Reconciliation bullet (chips filter, one primary button per row); IA.md (follow → "Belum final di Zahlungs", "Tinjau" → "Cek status SBI", chips filter).

- [ ] **Step 4: Run, watch them pass; then the whole suite and credo**

Run: `mix test test/zahlungs_web/live/deposit_live/reconcile_test.exs`, then `mix test`, then `mix credo`
Expected: all pass; credo "found no issues".

- [ ] **Step 5: Commit**

```bash
git add lib/zahlungs_web/live/deposit_live/reconcile.ex test/zahlungs_web/live/deposit_live/reconcile_test.exs CLAUDE.md docs/IA.md
git commit -m "feat(rapikan-rekonsiliasi): the kind chips filter the rows"
```
