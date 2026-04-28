# PR #5: Quality sweep + re-validation + coverage

**Author**: @mdon
**Status**: Merged (commit `43a7b44`)
**Date**: 2026-04-28
**URL**: https://github.com/BeamLabEU/phoenix_kit_ai/pull/5

## Goal

Bring the AI module up to the workspace AGENTS.md quality baseline and close the
findings that landed across PRs #1–#4. The PR also runs three re-validation
batches (Apr-26 sweep, fix-everything pass, coverage push) so the final state is
**522 tests, 0 failures, 90.93% line coverage, `mix precommit` clean**.

## Scope

Twelve commits, +7,671 / −1,199 across 55 files. The work splits into five tracks.

### 1. PR #1–#4 follow-ups (`ca6b9e6`, `3eb6d60`, `fa87c93`, `3662782`)

- Sanitise `raw_response` from request metadata.
- Log full stacktrace in the endpoint-form save rescue.
- New `PhoenixKitAI.Errors` module (atom-to-gettext map).
- Config-overridable embedding model list.
- HTTP error-path tests.
- Tighter prompt-variable regex (`^\w+$` retained, error vocabulary expanded).
- `Logger.warning` on legacy `endpoint.api_key` fallback; `api_key` field marked deprecated.
- Soft post-save flash when the chosen integration is disconnected.
- `safe_count/1` so `get_config/0` survives no-sandbox test runs.

### 2. Quality sweep — Batch 1 (`44d9458`)

- New `PhoenixKitAI.Errors` module routes every error atom / tagged tuple
  through gettext. Completion, OpenRouterClient, and `phoenix_kit_ai.ex` now
  return atoms (`:invalid_api_key`) and tagged tuples (`{:api_error, 503}`,
  `{:connection_error, reason}`, `{:prompt_error, :not_found}`) instead of raw
  strings. LiveViews surface them via `Errors.message/1` so business logic stays
  locale-agnostic.
- 8 mutation paths emit activity log entries (endpoint create/update/delete +
  enable toggle; same for prompt). `Code.ensure_loaded?/1` guard + rescue means
  hosts that haven't run the core activity migration yet silently no-op on
  `:undefined_table`.
- `phx-disable-with` on submit buttons. `unique_constraint` on `Endpoint.name`.
- `@type t :: %__MODULE__{}` on Endpoint, Prompt, Request.
- New test infra: `Test.Endpoint`, `Test.Router`, `Test.Layouts`, `LiveCase`,
  self-contained migration that creates ai + settings + activities tables plus
  the `uuid_generate_v7` function. ~70 new tests.

### 3. Re-validation Batch 2 (`3879714`, `faf099e`)

Apr-26 re-run of the post-Apr quality pipeline. Highlights:

- `phx-disable-with` on the three async/destructive `phx-click` sites the
  original sweep missed (`delete_endpoint`, `delete_prompt`, playground send).
- Catch-all `handle_info(_msg, socket)` `Logger.debug` clauses on all 4 admin
  LiveViews (two had no catch-all, two had silent ones).
- `pgcrypto` extension explicitly enabled in `test_helper.exs`
  (`uuid_generate_v7`'s `gen_random_bytes/1` dependency was implicit).
- `errors_test.exs` rewritten: `is_binary/1`-loop smell replaced with per-atom
  EXACT-string assertions. Adds `:api_key_forbidden` and `:model_not_found`
  atoms that were missing.
- 9 hard-coded heex strings wrapped in gettext; `String.capitalize(status)` →
  `Request.status_label/1` literal-gettext clauses.

### 4. Re-validation Batch 3 — fix everything (`1e14210`, `42e1752`, `13b1ed5`, `b3be793`)

- **SSRF guard on `Endpoint.base_url`** (`endpoint.ex:399-473`). Rejects
  non-http(s) schemes, missing host, IPv4 0/8, 10/8, 127/8, 169.254/16, 172.16/12,
  192.168/16, IPv6 `::`, `::1`, `fe80::/10`, `fc00::/7`, `localhost`, `*.local`.
  Bypass via `config :phoenix_kit_ai, allow_internal_endpoint_urls: true` for
  self-hosted Ollama / intranet deployments. Scheme guard fires even with bypass
  on. 12 pinning tests in `endpoint_test.exs`.
- Form refactor: `prompt_form.html.heex` fully on core `<.input>` /
  `<.select>` / `<.textarea>`; `endpoint_form.html.heex` partially refactored
  (Basic Info + Provider Configuration + Reasoning), bespoke provider/model
  picker grid stays raw because runtime-constructed field shapes don't fit
  `%Phoenix.HTML.FormField{}`.
- 31 `@spec` annotations across `phoenix_kit_ai.ex` and `request.ex`.
- 8 LV edge-case tests: Unicode round-trip, SQL metacharacter literal storage,
  >100-char name rejection, `:action = :validate` flow.

### 5. Re-validation Batch 4 — coverage push (`e4519a8`, `5bbf273`)

- Both HTTP entry points (`OpenRouterClient.http_get/2`,
  `Completion.http_post/3`) now read optional `Req` options from
  `Application.get_env(:phoenix_kit_ai, :req_options, [])`. Production diff: 6
  lines added, 0 removed. Tests opt in with `plug: {Req.Test, Stub}` to route
  HTTP through stubs without external traffic.
- 9 new test files, +299 tests. Total **522 tests**, line coverage
  **36.96% → 90.93%**.

### Late additions (`3d8c0a6`, `7b791e5`, `755dccc`)

After the original sweep landed locally, three small commits hardened the
endpoint form's `active_connection` wiring (single-connection auto-select kept
when current selection still exists; otherwise the picker shows the empty
state) plus tests that pin the new behaviour.

## Schema Changes

None. The migration plumbing is test-only — production schemas are unchanged.

## Verification

- `mix precommit` clean (compile + format + `credo --strict` + dialyzer).
- 522 tests, 10 / 10 stable runs.
- 90.93% line coverage via `mix test --cover`.

## Related

- PR #1: `dev_docs/pull_requests/2026/1-extract-ai-module/`
- PR #1 follow-up doc: `dev_docs/pull_requests/2026/1-extract-ai-module/FOLLOW_UP.md`
- PR #3: `dev_docs/pull_requests/2026/3-migrate-api-keys-to-integrations/`
