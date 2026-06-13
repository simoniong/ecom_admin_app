# Bulk Change Carrier — Design

**Date:** 2026-06-13
**Status:** Approved design (pre-implementation)

## Problem

17Track auto-detects the carrier for each tracking number. Occasionally (low
probability) it detects the **wrong carrier** or **none at all**, which breaks
tracking for that shipment. Agents need a way to manually set the correct
carrier — in bulk — so 17Track re-tracks correctly.

Overwriting our local carrier string is not enough: the carrier shown
(`origin_carrier` / `destination_carrier`) is derived from 17Track's
auto-detected `providers`, so a local-only change would be clobbered on the next
refresh. The fix must tell **17Track** the correct carrier via its carrier
**code**, then re-track.

## Goal

Add a **"Change carrier"** bulk action to the shipments selection hover bar that:
1. Lets the user pick a carrier from the full 17Track catalog (searchable).
2. Calls 17Track to actually change the carrier for the selected shipments.
3. Re-tracks so our DB reflects the corrected carrier/status.

## 17Track API facts (verified)

- **Change carrier:** `POST https://api.17track.net/track/v2.4/changecarrier`
  body `[{ "number": "...", "carrier_new": <int code> }]`.
  - `carrier_old` is **optional** — omit it when only one carrier is assigned
    (our case). So we do **not** need to know the old carrier code.
  - Limits: **40 numbers per call**, **max 5 changes per tracking number**.
  - Returns accepted + rejected (rejected carry an error code).
- **Register with carrier:** `POST .../register` accepts optional `carrier`
  (int code) and `auto_detection` (bool). Used as a fallback for numbers that
  were never successfully registered with any carrier.
- **Carrier codes** are numeric `key`s from 17Track's carrier catalog
  (`apicarrier.all.json`); each entry has `key`, `_name`, `_country_iso`, and
  localized names. Examples: USPS=21051, China Post=3011, China EMS=3013.

## Architecture

Chosen approach: **vendored carrier catalog + background job** (Approach A).

### 1. Data model

Add one nullable column to `fulfillments`:

- `carrier_code` (integer, nullable) — the 17Track carrier key last applied via
  this feature. Doubles as a "manually corrected" marker. Indexed is not
  required (no query filters on it in v1).

Migration only adds the column; no backfill.

### 2. Carrier catalog

- **Vendored snapshot:** `config/data/17track_carriers.json` — an array of
  trimmed entries `{ "code": <int>, "name": "<en name>", "country": "<ISO2>" }`
  (~2000 entries, ~150–250 KB). Committed to the repo so there is no runtime
  dependency on 17Track's asset host.
- **`CarrierCatalog`** (PORO under `app/services/`): loads and memoizes the
  snapshot. Public API:
  - `.all` → array of `{code, name, country}` (for the JSON endpoint)
  - `.valid?(code)` → boolean (controller validation)
  - `.name_for(code)` → string or nil
- **Refresh task:** `rake tracking:refresh_carriers` — server-side HTTParty GET
  of `https://res.17track.net/asset/carrier/info/apicarrier.all.json`, trims
  fields, rewrites the snapshot file. Run manually/periodically; carrier lists
  change slowly.
  - Implementation checkpoint: confirm the asset URL is fetchable server-side
    (WebFetch was blocked by user-agent during design). If not, source the list
    from the "Supported carriers and carrier codes" help export instead. The
    initial snapshot is produced by running this task once.
- **Endpoint:** `GET /shipments/carriers.json` → `CarrierCatalog.all`. The
  picker fetches this **lazily on first modal open** and caches it client-side.

### 3. UI — bulk hover bar

- New **"Change carrier"** button in the hover bar
  (`app/views/shipments/index.html.erb`, the `data-shipment-bulk-target="bar"`
  block), placed before the archive divider, mirroring the tag buttons.
- New **carrier modal** rendered once on the page (mirrors the tag modal
  pattern), containing a searchable carrier combobox.
- New Stimulus controller **`carrier_picker_controller.js`**:
  - On first open, `fetch` `/shipments/carriers.json`, cache the array.
  - Search input filters client-side (match on name or code; show ~50 results).
  - Selecting a carrier sets a hidden `carrier_code` field and enables Confirm.
- `shipment_bulk_controller.js` gains an **`openCarrierModal`** action (mirrors
  `openTagModal`): populates `ids[]` hidden inputs from the selected rows and
  sets the form action to `bulk_change_carrier_shipments_path`, then opens the
  modal.
- Confirm submits a POST form with `ids[]` + `carrier_code`.

### 4. Controller

`ShipmentsController#bulk_change_carrier` (route:
`post :bulk_change_carrier, on: :collection`):

- `require_tracking_enabled!` (existing before_action covers the controller).
- `ids = sanitize_ids(params[:ids])`; `code = params[:carrier_code].to_i`.
- Validate: `code` present and `CarrierCatalog.valid?(code)`, else redirect with
  an alert flash.
- `fulfillments = scoped_fulfillments(ids).with_tracking` (scoped to
  `visible_shopify_stores`).
- Enqueue `CarrierChangeJob.perform_later(current_company.id,
  fulfillments.pluck(:id), code)`.
- Redirect to `shipments_path(archived: params[:archived])` with a notice:
  "Queued carrier change for N shipments; tracking will update shortly."

`ShipmentsController#carriers` (route: `get :carriers, on: :collection`):
renders `CarrierCatalog.all` as JSON.

### 5. Service + background job

**`TrackingService#change_carrier(tracking_numbers, carrier_new:)`**
- Batches into groups of **40**; `POST /changecarrier` with
  `[{ number:, carrier_new: }]` per batch.
- Returns `{ accepted: [numbers], rejected: [{ number:, code: }] }`
  (parsed from `data.accepted` / `data.rejected`).

**`TrackingService#register`** — extend the existing method signature to accept
optional `carrier:` and `auto_detection:` keywords (backward compatible; current
caller `register(numbers)` keeps working). When `carrier` is present, include
`carrier` and `auto_detection: false` in each body entry.

**`CarrierChangeJob.perform(company_id, fulfillment_ids, carrier_code)`**
- Guard: company exists, `tracking_enabled?`, `tracking_api_key` present.
- Load scoped fulfillments by id; collect tracking numbers.
- Process in batches of 40:
  1. `service.change_carrier(numbers, carrier_new: carrier_code)`.
  2. **Fallback:** for every `rejected` number, `service.register(rejected,
     carrier: carrier_code, auto_detection: false)` (handles numbers never
     registered with a carrier). Log numbers still failing.
  3. Persist `carrier_code` on the fulfillments whose change/registration was
     accepted.
  4. `service.track(numbers)` and apply each result via
     `fulfillment.update_from_tracking_result(result)` to refresh DB.
- `retry_on StandardError` (mirror `TrackingRegisterJob`).

`carrier_old` is always omitted (single carrier per number).

### 6. Feedback

Asynchronous: the controller redirects immediately with a flash count. The job
re-tracks, so corrected carrier/status appear on the next page load or the
regular 10-minute refresh. (No live Turbo update in v1 — consistent with the
existing archive/tag bulk actions.)

## Error handling

- Invalid/blank `carrier_code` → controller rejects with an alert flash; no job.
- Per-number `change_carrier` rejection → register fallback; persistent failures
  are logged (not surfaced per-number in v1).
- 17Track's 5-changes-per-number limit and any auth errors surface as rejections
  / job errors and are logged; the job's `retry_on` covers transient failures.
- IDs are scoped to `visible_shopify_stores`, so a user cannot change carriers
  for shipments outside their company/permissions.

## Testing

- **Service spec** (`change_carrier`): WebMock-stub `/changecarrier`; assert
  request body shape, ≤40 batching, accepted/rejected parsing. Extend register
  spec for the `carrier:` keyword.
- **Job spec** (`CarrierChangeJob`): real DB; stub changecarrier + gettrackinfo;
  assert `carrier_code` persisted, fallback register called for rejected,
  `update_from_tracking_result` applied.
- **Request spec** (`bulk_change_carrier`): enqueues job, scopes to visible
  stores, rejects invalid carrier_code, flash; `carriers` returns JSON.
- **Catalog spec** (`CarrierCatalog`): parsing, `valid?`, `name_for`.
- **System spec**: select shipments → open carrier modal → search → pick →
  submit → flash (runs in CI; no local Chrome).
- Locales: en / zh-CN / zh-TW strings for button, modal, flashes.

## Out of scope (YAGNI)

- Per-number success/failure UI (v1 logs + relies on refresh).
- Live carrier-list sync on every request (vendored snapshot + manual refresh).
- Carrier `param` field for carriers needing extra disambiguation.
- Single-shipment carrier change on the show page (could reuse the service
  later; not part of this feature).
