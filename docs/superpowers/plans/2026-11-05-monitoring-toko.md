# Monitoring Toko Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Halaman `/platform/monitoring` untuk superadmin: keadaan semua organisasi (keaktifan, angka usaha, tagihan, masalah layanan), dengan rincian per cabang.

**Architecture:** Modul baca baru `Zahlungs.Monitoring` menghitung semua organisasi sekali jalan lewat kueri agregat dengan jumlah tetap, lalu menggabungnya dalam Elixir. LiveView `PlatformLive.Monitoring` memegang hasilnya; saringan, halaman, dan buka-tutup rincian hanya mengolah hasil itu. Tidak ada tabel baru, migrasi, penulisan ke database, atau panggilan ke provider.

**Tech Stack:** Elixir, Phoenix LiveView 1.2, Ecto + MySQL/MariaDB, ExUnit + `ZahlungsWeb.LiveDriver`.

**Spec:** `docs/superpowers/specs/2026-11-05-monitoring-toko-design.md`

## Global Constraints

- Kode, komentar, nama tes, dan pesan commit dalam bahasa Inggris; teks layar dalam bahasa Indonesia.
- Commit hanya di `feat/monitoring-toko`, format `type(monitoring-toko): subject`, diakhiri `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Tanpa push dan tanpa merge. `.claude/launch.json` tidak ikut.
- Tidak ada dependensi baru.
- Setiap kueri pada schema berkolom `organization_id` (`Store`, `UserLogin`, `Deposits.Account`) memakai `skip_org_id: true`. `Sale`, `Services.Transaction`, `Shift`, `Deposits.Entry` disaring dengan id milik organisasi yang didaftar, tidak pernah tanpa saringan.
- Tidak pernah membaca atau menampilkan: `credentials`, `provider_payload`, `provider_message`, `customer_ref`, `customer_name`, `customer_details`, `token_sn`, `bill_reference`, `meter_reading`, nama kasir, serta IP, posisi, dan browser dari `user_logins`. Juga tidak menampilkan `billing_note` dan `review_note`.
- Tes tidak menebak total seluruh database dan tidak memakai nilai dari database dev; semua nilai rekaan. Baris dicari lewat organisasi buatan tes; ringkasan diuji sebagai selisih sebelum dan sesudah.
- Tes tidak memanggil SBI.
- Layar tidak boleh melebar di 375 px: kartu, bukan tabel; teks panjang memakai `break-words`.

## Review Focus

1. Berada di halaman 5 lalu menyaring sampai hasilnya tinggal satu halaman: halaman jatuh ke halaman terakhir yang ada, bukan daftar kosong. Tes di Task 5.
2. Organisasi `pending`, `suspended`, dan `rejected` yang punya penjualan atau tagihan lewat: tidak masuk ringkasan, walau tetap tampil bila statusnya dipilih. Tes di Task 4.
3. Satu akun deposit dipakai dua cabang dan saldonya minus: terhitung satu, bukan dua, dan tampil sekali. Tes di Task 3.
4. Admin yang login tanpa cabang (`store_id` kosong): login terakhir tercatat di organisasi, tidak di cabang mana pun, dan tidak membuat galat. Tes di Task 2.
5. Pencarian berisi spasi di tepi, atau hanya spasi: spasi tepi diabaikan, hanya spasi berarti tanpa pencarian. Tes di Task 4.

---

### Task 1: Aturan keaktifan dan tagihan

**Files:**
- Create: `lib/zahlungs/monitoring.ex`
- Modify: `lib/zahlungs/services.ex` (di sekitar `@settle_by_hand_after`)
- Test: `test/zahlungs/monitoring_test.exs`

**Interfaces:**
- Produces: `Monitoring.activity(last_at :: NaiveDateTime.t() | nil, now :: NaiveDateTime.t()) :: :active | :quiet | :asleep | :never`
- Produces: `Monitoring.billing(%Organization{}, today :: Date.t()) :: :unrecorded | :overdue | :due_soon | :ok | nil`
- Produces: `Services.settle_by_hand_after() :: 600` (detik)

- [ ] **Step 1: Tulis tes yang gagal**

Modul `Zahlungs.MonitoringTest`, `use Zahlungs.DataCase, async: true`. Dengan `now = ~N[2026-11-05 12:00:00]` dan `ago(seconds) = NaiveDateTime.add(now, -seconds)`:

```elixir
describe "activity/2" do
  test "the edge of a band belongs to the more active one" do
    assert Monitoring.activity(ago(7 * 86_400), @now) == :active
    assert Monitoring.activity(ago(7 * 86_400 + 1), @now) == :quiet
    assert Monitoring.activity(ago(30 * 86_400), @now) == :quiet
    assert Monitoring.activity(ago(30 * 86_400 + 1), @now) == :asleep
  end

  test "no transaction at all is never" do
    assert Monitoring.activity(nil, @now) == :never
  end
end

describe "billing/2" do
  # today = ~D[2026-11-05]
  test "an active organization by its paid-until date" do
    assert Monitoring.billing(org(paid_until: nil), @today) == :unrecorded
    assert Monitoring.billing(org(paid_until: ~D[2026-11-04]), @today) == :overdue
    assert Monitoring.billing(org(paid_until: ~D[2026-11-05]), @today) == :due_soon
    assert Monitoring.billing(org(paid_until: ~D[2026-11-12]), @today) == :due_soon
    assert Monitoring.billing(org(paid_until: ~D[2026-11-13]), @today) == :ok
  end

  test "an organization that isn't active has no billing state" do
    for status <- ~w(pending suspended rejected) do
      assert Monitoring.billing(org(status: status, paid_until: ~D[2026-01-01]), @today) == nil
    end
  end
end

test "the wait before a service counts as stuck has one source" do
  assert Zahlungs.Services.settle_by_hand_after() == 600
end
```

`org/1` membangun `%Organization{status: "active"}` tanpa menyimpannya.

- [ ] **Step 2: Jalankan, pastikan gagal**

Run: `mix test test/zahlungs/monitoring_test.exs`
Expected: FAIL, `Zahlungs.Monitoring` belum ada.

- [ ] **Step 3: Implementasi**

`activity/2` memakai `NaiveDateTime.diff(now, last_at)`. `billing/2` memakai `Date.compare` dan `Date.add(today, 7)`. `Services.settle_by_hand_after/0` mengembalikan `@settle_by_hand_after`. `@moduledoc` menyatakan modul ini satu-satunya pembacaan lintas organisasi untuk monitoring, hanya untuk halaman `/platform`, dan tidak menulis apa pun.

- [ ] **Step 4: Jalankan, pastikan lulus**

Run: `mix test test/zahlungs/monitoring_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

Ikutkan spec dan plan, karena keduanya belum di-commit.

```bash
git add docs/superpowers/specs/2026-11-05-monitoring-toko-design.md docs/superpowers/plans/2026-11-05-monitoring-toko.md lib/zahlungs/monitoring.ex lib/zahlungs/services.ex test/zahlungs/monitoring_test.exs
git commit -m "feat(monitoring-toko): the activity and billing rules of the operator's monitoring" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Angka per cabang dan per organisasi

**Files:**
- Modify: `lib/zahlungs/monitoring.ex`
- Test: `test/zahlungs/monitoring_test.exs`

**Interfaces:**
- Consumes: `activity/2`, `billing/2` (Task 1); `Organizations.list_organizations/0`
- Produces: `Monitoring.overview(days :: 7 | 30, now \\ NaiveDateTime.utc_now()) :: %{rows: [row], summary: summary, at: NaiveDateTime.t()}`, dengan bentuk `row` persis seperti di spec. Field masalah dan `deposits` diisi di Task 3, `summary` di Task 4; sampai saat itu bernilai 0, `[]`, dan `%{}`.

- [ ] **Step 1: Tulis tes yang gagal**

Helper tes:

- `shop/0`: di dalam `in_org(organization_fixture(), ...)` membuat cabang dengan `store_fixture/1`, kasir dengan `user_fixture(store_id: store.id)`, dan shift. Mengembalikan `%{org, store, cashier, shift}`.
- `sale!(ctx, attrs)`: `Repo.insert!(%Sale{...})` dengan `store_id`, `shift_id`, `user_id`, `code` unik, `total`, `status`, dan `inserted_at` dari `attrs`.
- `service!(ctx, attrs)`: `Repo.insert!(%Transaction{...})` serupa, dengan `price`, `cost`, `status`, `channel`.
- `row_of(overview, org)`: `Enum.find(overview.rows, &(&1.organization.id == org.id))`.
- Setiap `overview` yang diuji memanggil `Repo.put_org_id(nil)` lebih dulu, lewat helper `overview(days \\ 30)`, supaya `skip_org_id` yang terlupa gagal, bukan tersaring diam-diam.

```elixir
test "runs without a current organization and reads every organization" do
  a = shop(); b = shop()
  sale!(a, total: "1000", at: ago(3600))
  sale!(b, total: "2000", at: ago(3600))

  overview = overview()

  assert Decimal.equal?(row_of(overview, a.org).sales_total, 1000)
  assert Decimal.equal?(row_of(overview, b.org).sales_total, 2000)
  assert [%{id: id}] = row_of(overview, a.org).stores
  assert id == a.store.id
end

test "only completed sales count, from the start of the window to now" do
  a = shop()
  sale!(a, total: "100", at: ago(30 * 86_400))
  sale!(a, total: "10", at: ago(30 * 86_400 + 1))
  sale!(a, total: "1000", status: "returned", at: ago(3600))
  sale!(a, total: "1000", status: "void", at: ago(3600))

  row = row_of(overview(30), a.org)
  assert Decimal.equal?(row.sales_total, 100)
  assert row.sales_count == 1
  assert row_of(overview(7), a.org).sales_count == 0
end

test "goods revenue follows the sales report's rule" do
  # A real sale through Sales.create_sale/3, a returned one too.
  assert Decimal.equal?(row_of(overview(), a.org).sales_total, Sales.sales_report(scope, today, today).revenue)
end

test "only successful services count, by what the customer paid" do
  a = shop()
  service!(a, price: "500", status: "success", at: ago(3600))
  service!(a, price: "70", status: "processing", at: ago(3600))
  service!(a, price: "70", status: "failed", at: ago(3600))

  row = row_of(overview(), a.org)
  assert Decimal.equal?(row.services_total, 500)
  assert row.services_count == 1
end

test "any sale or service, whatever its status, is a last transaction" do
  a = shop()
  sale!(a, status: "void", at: ago(3 * 86_400))
  service!(a, status: "failed", at: ago(9 * 86_400))
  row = row_of(overview(), a.org)
  assert row.last_transaction_at == ago(3 * 86_400)
  assert row.activity == :active
end

test "a closed store has no activity and isn't counted as quiet, but its money counts" do
  a = shop()
  closed = in_org(a.org, fn -> store_fixture(active: false) end)
  sale!(%{a | store: closed}, total: "300", at: ago(3600))

  row = row_of(overview(), a.org)
  assert %{activity: nil, active: false} = Enum.find(row.stores, &(&1.id == closed.id))
  assert row.active_stores == 1
  assert row.quiet_stores == 1  # the open store, which has no transaction
  assert Decimal.equal?(row.sales_total, 300)
end

test "an organization without a store appears with zeros" do
  org = organization_fixture()
  row = row_of(overview(), org)
  assert row.stores == []
  assert row.activity == :never
  assert row.sales_count == 0
  assert Decimal.equal?(row.sales_total, 0)
end

test "open shifts are counted per store and summed" do
  a = shop()
  assert row_of(overview(), a.org).open_shifts == 1
end

test "a login without a store counts for the organization only" do
  a = shop()
  admin_login!(a, store_id: nil, at: ago(3600))   # UserLogin with organization_id, no store
  row = row_of(overview(), a.org)
  assert row.last_login_at == ago(3600)
  assert hd(row.stores).last_login_at == nil
end

test "a login at a store counts for the store and the organization" do
  a = shop()
  admin_login!(a, store_id: a.store.id, at: ago(7200))
  row = row_of(overview(), a.org)
  assert row.last_login_at == ago(7200)
  assert hd(row.stores).last_login_at == ago(7200)
end
```

Isi tes `goods revenue` menyiapkan produk berstok di cabang itu (contoh: `test/zahlungs/multi_store_test.exs`), lalu dua penjualan lewat `Sales.create_sale/3` dan satu `return_sale/2`.

- [ ] **Step 2: Jalankan, pastikan gagal**

Run: `mix test test/zahlungs/monitoring_test.exs`
Expected: FAIL, `overview` belum ada.

- [ ] **Step 3: Implementasi `overview/2`**

Satu kueri per angka: cabang; transaksi terakhir penjualan (`max(inserted_at)` per `store_id`, semua status); transaksi terakhir layanan; total penjualan `completed` dengan `inserted_at >= start and inserted_at <= now`; total layanan `success` dengan jendela yang sama; shift `status == "open"` per `store_id`; login terakhir per `organization_id` dan per `store_id`. Masing-masing `select` hanya id dan agregat. `start = NaiveDateTime.add(now, -days * 86_400)`. Hasil jadi map berkunci id, lalu digabung; hasil `sum` dinormalkan ke `Decimal`, yang kosong jadi `Decimal.new(0)`.

- [ ] **Step 4: Jalankan, pastikan lulus**

Run: `mix test test/zahlungs/monitoring_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/zahlungs/monitoring.ex test/zahlungs/monitoring_test.exs
git commit -m "feat(monitoring-toko): each organization's and store's figures, across organizations" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Masalah layanan dan saldo deposit

**Files:**
- Modify: `lib/zahlungs/monitoring.ex`
- Test: `test/zahlungs/monitoring_test.exs`

**Interfaces:**
- Consumes: `overview/2` (Task 2), `Services.settle_by_hand_after/0` (Task 1)
- Produces: pada `row`: `stuck`, `refunds_due`, `in_review`, `negative_deposits`, `problem?`, `deposits: [%{id, name, balance}]`; pada baris `stores`: `stuck`, `refunds_due`, `in_review`.

- [ ] **Step 1: Tulis tes yang gagal**

```elixir
test "an api service is stuck from ten minutes, a manual one never" do
  a = shop()
  service!(a, channel: "api", status: "processing", at: ago(599))
  assert row_of(overview(), a.org).stuck == 0

  service!(a, channel: "api", status: "processing", at: ago(600))
  service!(a, channel: "manual", status: "processing", at: ago(86_400))
  row = row_of(overview(), a.org)
  assert row.stuck == 1
  assert hd(row.stores).stuck == 1
  assert row.problem?
end

test "a failed api service is due a refund until refunded, unless in review" do
  a = shop()
  service!(a, channel: "api", status: "failed", at: ago(3600))
  service!(a, channel: "api", status: "failed", refunded_at: ago(60), at: ago(3600))
  service!(a, channel: "manual", status: "failed", at: ago(3600))
  service!(a, channel: "api", status: "failed", review_reason: "Uji", at: ago(3600))

  row = row_of(overview(), a.org)
  assert row.refunds_due == 1
  assert row.in_review == 1
end

test "a balance is the same as the deposit page's estimate" do
  a = shop_with_account()
  topup!(a, "1000")          # Deposits.record_correction/3
  service!(a, cost: "300", status: "success", at: ago(3600))
  service!(a, cost: "200", status: "processing", at: ago(3600))
  service!(a, cost: "999", status: "failed", at: ago(3600))

  [deposit] = row_of(overview(), a.org).deposits
  expected = in_org(a.org, fn -> Deposits.estimated_balance(a.account) end)
  assert Decimal.equal?(deposit.balance, expected)
  assert Decimal.equal?(deposit.balance, 500)
end

test "only a balance below zero counts" do
  a = shop_with_account()
  assert row_of(overview(), a.org).negative_deposits == 0   # zero isn't below zero

  service!(a, cost: "1", status: "success", at: ago(3600))
  row = row_of(overview(), a.org)
  assert row.negative_deposits == 1
  assert row.problem?
end

test "an inactive account is neither listed nor counted" do
  a = shop_with_account(active: false)
  service!(a, cost: "1", status: "success", at: ago(3600))
  row = row_of(overview(), a.org)
  assert row.deposits == []
  assert row.negative_deposits == 0
end

test "an account two stores share counts once" do
  a = shop_with_account()
  other = in_org(a.org, fn -> assign_account(store_fixture(), a.account) end)
  service!(a, cost: "1", status: "success", at: ago(3600))
  service!(%{a | store: other}, cost: "1", status: "success", at: ago(3600))

  row = row_of(overview(), a.org)
  assert [_one] = row.deposits
  assert row.negative_deposits == 1
end

test "one organization's problems stay its own" do
  a = shop(); b = shop()
  service!(a, channel: "api", status: "processing", at: ago(3600))
  refute row_of(overview(), b.org).problem?
end
```

`shop_with_account/1` adalah `shop/0` plus `deposit_account_fixture/1` yang dipasang ke cabangnya, dan `service!` mengisi `deposit_account_id` dari `ctx[:account]`.

- [ ] **Step 2: Jalankan, pastikan gagal**

Run: `mix test test/zahlungs/monitoring_test.exs`
Expected: FAIL pada angka masalah dan `deposits`.

- [ ] **Step 3: Implementasi**

Satu kueri agregat per `store_id` dengan tiga `sum(CASE ...)`, atau tiga kueri, pilih yang lebih mudah dibaca. Batas tertahan: `inserted_at <= now - Services.settle_by_hand_after()`. Akun: `id, name, organization_id` dari akun `active`, dengan `skip_org_id: true`; `coalesce(sum(amount), 0)` per akun dari `Deposits.Entry`; `coalesce(sum(cost), 0)` per akun dari `Transaction` berstatus `processing`, `success`. `problem?` benar bila salah satu dari empat angka lebih dari nol.

- [ ] **Step 4: Jalankan, pastikan lulus**

Run: `mix test test/zahlungs/monitoring_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/zahlungs/monitoring.ex test/zahlungs/monitoring_test.exs
git commit -m "feat(monitoring-toko): stuck services, refunds due, reviews and negative deposits" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Urutan, ringkasan, dan saringan

**Files:**
- Modify: `lib/zahlungs/monitoring.ex`
- Test: `test/zahlungs/monitoring_test.exs`

**Interfaces:**
- Consumes: `overview/2` (Task 2 dan 3)
- Produces: `overview/2` mengembalikan `rows` terurut dan `summary` berisi `%{active_organizations, sales_total, services_total, overdue, with_problems}`.
- Produces: `Monitoring.filter(rows, opts) :: rows`, dengan `opts`: `status: "" | status`, `quick: "" | "quiet" | "billing" | "problems"`, `search: binary`. Nilai status atau `quick` yang tidak dikenal berarti tanpa saringan itu. Urutan tidak berubah.

- [ ] **Step 1: Tulis tes yang gagal**

```elixir
test "what needs handling comes first, then by name" do
  problem = shop_named("Zeta");       service!(problem, channel: "api", status: "processing", at: ago(3600))
  overdue = shop_named("Yota", paid_until: yesterday)
  asleep  = shop_named("Xeno");       sale!(asleep, at: ago(31 * 86_400))
  quiet   = shop_named("Wira");       sale!(quiet, at: ago(8 * 86_400))
  busy_b  = shop_named("beta");       sale!(busy_b, at: ago(3600))
  busy_a  = shop_named("Alfa");       sale!(busy_a, at: ago(3600))

  ids = overview().rows |> Enum.map(& &1.organization.id)
  wanted = [problem, overdue, asleep, quiet, busy_a, busy_b] |> Enum.map(& &1.org.id)

  assert Enum.filter(ids, &(&1 in wanted)) == wanted
end

test "the summary covers active organizations only" do
  before = overview().summary

  a = shop()
  sale!(a, total: "100", at: ago(3600))
  service!(a, price: "40", status: "success", at: ago(3600))

  for status <- ~w(pending suspended rejected) do
    other = shop(status: status, paid_until: ~D[2020-01-01])
    sale!(other, total: "9000", at: ago(3600))
    service!(other, channel: "api", status: "processing", at: ago(3600))
  end

  overdue = shop(paid_until: ~D[2020-01-01])
  troubled = shop(); service!(troubled, channel: "api", status: "processing", at: ago(3600))

  now = overview().summary
  assert now.active_organizations - before.active_organizations == 3
  assert Decimal.equal?(Decimal.sub(now.sales_total, before.sales_total), 100)
  assert Decimal.equal?(Decimal.sub(now.services_total, before.services_total), 40)
  assert now.overdue - before.overdue == 1
  assert now.with_problems - before.with_problems == 1
end

describe "filter/2" do
  test "status: one, every, or an unknown value means every" do ... end
  test "quick quiet takes quiet, asleep and never; not active" do ... end
  test "quick billing takes overdue, due soon and unrecorded; not ok" do ... end
  test "quick problems takes only organizations with a problem" do ... end
  test "search: part of the name, any case; % and _ are text" do
    assert names(filter(rows, search: "aLf")) == ["Alfa"]
    assert filter(rows, search: "%") == []
    assert filter(rows, search: "_") == []
  end
  test "search: edge spaces are ignored and only spaces is no search" do
    assert names(filter(rows, search: "  alf ")) == ["Alfa"]
    assert filter(rows, search: "   ") == rows
  end
  test "keeps the order" do ... end
end
```

Tes `filter/2` memakai daftar `row` buatan tangan yang hanya berisi field yang dibaca `filter/2`, tanpa database. Isi tes bertanda `...` menyatakan judulnya: satu `assert` per kelompok yang masuk dan `refute` per kelompok yang keluar. `shop/1` menerima `status` dan `paid_until` untuk `organization_fixture/1`; `shop_named/2` menambahkan nama.

- [ ] **Step 2: Jalankan, pastikan gagal**

Run: `mix test test/zahlungs/monitoring_test.exs`
Expected: FAIL.

- [ ] **Step 3: Implementasi**

Kunci urut:

```elixir
{rank, String.downcase(name), id}
# rank: problem? -> 0; billing == :overdue -> 1; activity == :asleep -> 2;
#       activity == :quiet -> 3; else -> 4
```

`filter/2` memakai `String.contains?` atas nama yang di-`downcase` dan pencarian yang di-`trim`.

- [ ] **Step 4: Jalankan, pastikan lulus**

Run: `mix test test/zahlungs/monitoring_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/zahlungs/monitoring.ex test/zahlungs/monitoring_test.exs
git commit -m "feat(monitoring-toko): the order, summary and filters of the overview" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Halaman `/platform/monitoring`

**Files:**
- Create: `lib/zahlungs_web/live/platform_live/monitoring.ex`
- Modify: `lib/zahlungs_web/router.ex` (blok `:require_platform_admin`)
- Modify: `lib/zahlungs_web/components/layouts.ex` (`platform_links/0`)
- Test: `test/zahlungs_web/live/platform_live/monitoring_test.exs`

**Interfaces:**
- Consumes: `Monitoring.overview/2`, `Monitoring.filter/2`
- Produces: `Monitoring.local_time(store_row :: map, at :: NaiveDateTime.t() | nil) :: NaiveDateTime.t() | nil`
- Produces: rute `live "/monitoring", PlatformLive.Monitoring, :index`; event `period` (`%{"days" => _}`), `filter` (`%{"status" => _, "search" => _}`), `quick` (`%{"quick" => _}`), `page` (`%{"to" => _}`), `toggle` (`%{"id" => _}`).

Teks layar:

| Tempat | Teks |
|---|---|
| Judul, subjudul | `Monitoring`, `Keadaan semua organisasi yang terdaftar. Hanya ringkasan, tanpa isi transaksi.` |
| Waktu hitung | `Angka per 14.32. Muat ulang halaman untuk memperbarui.` |
| Kartu ringkasan | `Organisasi aktif`, `Omzet barang`, `Omzet layanan`, `Tagihan lewat`, `Organisasi bermasalah` |
| Rincian | `Akun deposit` |
| Periode | `7 hari`, `30 hari` |
| Tombol cepat | `Semua`, `Sepi/Tidur`, `Tagihan`, `Masalah layanan` |
| Keaktifan | `Aktif`, `Sepi`, `Tidur`, `Belum pernah`; cabang tutup: `Nonaktif` |
| Tagihan | `Tagihan lewat`, `Segera jatuh tempo`, `Tagihan belum dicatat` |
| Masalah | `Tertahan`, `Perlu dikembalikan`, `Menunggu keputusan`, `Saldo minus` |
| Cabang | `1 dari 3 cabang sepi`, `Lihat cabang`, `Tutup cabang` |
| Kosong | `Tidak ada organisasi yang cocok.` |

- [ ] **Step 1: Tulis tes yang gagal**

`use ZahlungsWeb.ConnCase, async: true`, membuat data dengan pola Task 2. Hindari `ago` yang bergantung `now` tetap; memakai `NaiveDateTime.utc_now()`.

```elixir
describe "access" do
  test "guests are sent to log in", %{conn: conn} do
    assert conn |> get("/platform/monitoring") |> redirected_to() == "/users/log_in"
  end

  test "an organization's admin and a cashier are turned away", %{conn: conn} do
    {:ok, admin} = Accounts.set_user_role(user_fixture(), "admin")
    assert conn |> log_in_user(admin) |> get("/platform/monitoring") |> redirected_to() == "/"
    assert build_conn() |> log_in_user(user_fixture()) |> get("/platform/monitoring") |> redirected_to() == "/"
  end

  test "the operator sees the page and its menu link", %{conn: conn} do
    html = conn |> log_in_user(superadmin_fixture()) |> get("/platform/monitoring") |> html_response(200)
    assert html =~ "Monitoring"
    assert html =~ ~s(href="/platform/monitoring")
  end
end

describe "behaviour" do
  test "starts on active organizations and thirty days" do
    # An active and a suspended organization, named uniquely.
    # A sale 10 days ago shows in the card at 30 days and not at 7.
  end

  test "period: 7 and 30 as a number or text, anything else is 30" do
    assert socket |> event("period", %{"days" => 7}) |> Map.fetch!(:assigns) |> Map.fetch!(:days) == 7
    assert socket |> event("period", %{"days" => "7"}) |> ... == 7
    assert socket |> event("period", %{"days" => "abc"}) |> ... == 30
    assert socket |> event("period", %{"days" => 1}) |> ... == 30
  end

  test "filters: status, search and the quick buttons narrow the list" do ... end

  test "changing a filter goes back to page one" do ... end

  test "a page past the end falls back to the last one that exists" do
    # 26 organizations sharing a unique word in their name, searched for it:
    # page 2 has one; searching for that one name leaves page 1 with a card.
    socket = socket |> event("filter", search(word)) |> event("page", %{"to" => 2})
    socket = event(socket, "filter", search(one_name))
    assert html(socket) =~ one_name
    refute html(socket) =~ "Tidak ada organisasi yang cocok."
  end

  test "page: a number or text, and below one is one" do ... end

  test "details open and close, by a number or text, and stay open across a period change" do
    socket = event(socket, "toggle", %{"id" => org.id})
    assert html(socket) =~ store.name
    socket = event(socket, "period", %{"days" => 7})
    assert html(socket) =~ store.name
    socket = event(socket, "toggle", %{"id" => to_string(org.id)})
    refute html(socket) =~ store.name
  end

  test "a store's times use that store's zone" do
    store_row = %{utc_offset_hours: 9}
    assert Monitoring.local_time(store_row, ~N[2026-11-05 00:00:00]) == ~N[2026-11-05 09:00:00]
    assert Monitoring.local_time(store_row, nil) == nil
  end

  test "an id that isn't a number changes nothing" do
    assert html(event(socket, "toggle", %{"id" => "abc"})) == html(socket)
  end
end

describe "what the page never shows" do
  test "a customer's, cashier's or provider's details, also with details open" do
    # Made-up values, on a real row of each kind:
    # customer_ref "089900001111", customer_name "NAMA-PELANGGAN-UJI",
    # token_sn "TOKEN-UJI-123", provider_payload "PAYLOAD-UJI",
    # provider_message "PESAN-UJI", bill_reference "REF-UJI", meter_reading "METER-UJI",
    # cashier name "KASIR-UJI", login ip "203.0.113.77",
    # api account credentials with secret "rahasia-uji",
    # billing_note "TAGIHAN-UJI", review_note "TINJAU-UJI".
    html = socket |> event("toggle", %{"id" => org.id}) |> html()
    assert html =~ store.name
    for secret <- secrets, do: refute html =~ secret
  end
end
```

Bagian yang tertulis `...` dan komentar menyatakan judul tesnya: isi dengan `event/3` dan `html/1` terhadap organisasi bernama unik.

- [ ] **Step 2: Jalankan, pastikan gagal**

Run: `mix test test/zahlungs_web/live/platform_live/monitoring_test.exs`
Expected: FAIL, rute dan modul belum ada.

- [ ] **Step 3: Tambahkan rute dan menu**

`live "/monitoring", PlatformLive.Monitoring, :index` di dalam `live_session :require_platform_admin`. `{"Monitoring", ~p"/platform/monitoring"}` di `platform_links/0`, setelah "Organisasi".

- [ ] **Step 4: Implementasi LiveView**

Assign: `days` 30, `status` `"active"`, `quick` `""`, `search` `""`, `page` 1, `open` `MapSet`, `overview`. `@per_page 25`, kartu dari `@visible`.

- `mount/3` dan event `period` menjalankan `Monitoring.overview/1`. Event lain tidak menjalankannya.
- `refresh/1`: `Monitoring.filter/2`, lalu halaman dijepit ke `1..max(1, ceil(total / per_page))`, lalu `Enum.slice`; `total` untuk `.pagination`.
- `filter` dan `quick` mengembalikan `page` ke 1. `page` dan `toggle` menerima angka dan teks; id yang bukan angka diabaikan memakai `Integer.parse/1`. `days` selain 7 dan 30 menjadi 30.
- Pencarian memakai `phx-debounce="300"`.
- `page_title` `"Monitoring"`.
- Waktu kartu organisasi: `LocalTime.to_local(at)`. Waktu cabang: `Monitoring.local_time(store_row, at)`, yang memanggil `LocalTime.to_local(at, %Store{utc_offset_hours: hours})`. Struct itu wajib: `LocalTime.offset_seconds/1` diam-diam memakai offset bawaan untuk map biasa. Format `%d %b %Y %H:%M`; nilai kosong `—`.
- Uang: `format_price/1`.
- Kartu: `rounded-lg border border-gray-200 p-4`, pembungkus `flex flex-wrap`, teks panjang `min-w-0 break-words`, seperti `PlatformLive.Organizations`. Tanpa `<table>`.

- [ ] **Step 5: Jalankan, pastikan lulus**

Run: `mix test test/zahlungs_web/live/platform_live/monitoring_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/zahlungs_web/live/platform_live/monitoring.ex lib/zahlungs_web/router.ex lib/zahlungs_web/components/layouts.ex test/zahlungs_web/live/platform_live/monitoring_test.exs
git commit -m "feat(monitoring-toko): the operator's monitoring page" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Dokumen dan verifikasi akhir

**Files:**
- Modify: `CLAUDE.md` (bagian Multi-tenant)
- Modify: `docs/IA.md`
- Modify: `docs/SAAS-multi-pemilik.md`

**Interfaces:**
- Consumes: semua task sebelumnya.

- [ ] **Step 1: Perbarui dokumen**

`CLAUDE.md`: satu butir di Multi-tenant: `Monitoring` (`/platform/monitoring`, `Zahlungs.Monitoring`), hanya membaca, hanya agregat, dihitung saat halaman dibuka, batas keaktifan 7 dan 30 hari, dan saldo minus sebagai satu-satunya tanda saldo. `docs/IA.md` dan `docs/SAAS-multi-pemilik.md`: halaman baru dan siapa yang bisa melihatnya, juga bahwa operator melihat total omzet tiap toko.

- [ ] **Step 2: Jalankan pemeriksaan penuh**

Run: `mix format --check-formatted`
Expected: tanpa keluaran.

Run: `mix test`
Expected: 0 failures.

- [ ] **Step 3: Periksa di browser**

Superadmin dibutuhkan: minta pengguna login sendiri sebagai operator di panel browser. Jangan mengetik kata sandi dan jangan keluar dari sesi tanpa diminta. Bila belum login, laporkan bagian ini sebagai belum diperiksa.

Di 1280 px dan 375 px: `/platform/monitoring` tidak melebar (`document.documentElement.scrollWidth <= innerWidth`), menu superadmin muat di navbar, rincian bisa dibuka, saringan dan periode berjalan. Hanya melihat, tanpa data uji baru. Angka dari database dev tidak disalin ke kode, tes, dokumen, atau commit.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md docs/IA.md docs/SAAS-multi-pemilik.md
git commit -m "docs(monitoring-toko): the operator's monitoring page" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
