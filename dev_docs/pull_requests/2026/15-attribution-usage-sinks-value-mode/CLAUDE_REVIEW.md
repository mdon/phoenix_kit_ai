# PR #15 — Add attribution metadata, usage-sink dispatch, and AI-translate VALUE MODE

**Reviewed:** 2026-08-10 · **Author:** mdon · **Verdict:** merged into `main`, no changes required.

Reviewed as part of the phoenix_kit 2.0 ecosystem sweep
(`../../../../../dev_docs/2026-08-10-phoenix-kit-2.0-ecosystem-sweep.md` at the
umbrella root). Released in **0.18.0** together with the core `~> 2.0` pin.

## What it does

Four commits across 6 source files (+277/−61):

1. **Attribution metadata** — callers may pass `attribution: %{...}` to any AI
   call. `normalize_attribution/1` stringifies keys and returns `nil` for
   non-maps/empty maps; `maybe_put_attribution/2` folds it into request
   metadata. This package records it verbatim and never interprets it.
2. **Usage-sink dispatch** — `PhoenixKitAI.dispatch_usage_sinks/1` offers every
   persisted `%Request{}` to each discovered module exporting
   `handle_ai_usage/1`. Called from `create_request/1` on the success path only.
3. **Hardening + docs** — the sink loop catches `kind, reason` (not just
   `rescue`), and `Request.cost_cents` gains a comment naming the unit misnomer.
4. **VALUE MODE** — optional `FormBinding.source_fields/2` callback enables AI
   translation on unsaved (`:new`) forms.

## Verification performed

| Check | Result |
|---|---|
| `mix precommit` (compile warnings-as-errors, deps.unlock, format, credo --strict, dialyzer) | **passes, 0 errors** — against core **2.0.0** |
| `mix test` | **332 tests, 0 failures** (545 DB-backed tests excluded — no Postgres in the review environment) |
| Merge into `main` | clean fast-forward |

## Points checked specifically

**`PhoenixKit.ModuleRegistry.all_modules/0` and `PhoenixKit.TaskSupervisor` both
exist in core 2.0.0.** Confirmed at `module_registry.ex:92` and
`supervisor.ex:104` respectively. The PR body said it depended on core #692;
that shipped in 2.0.0, so the dependency is satisfied.

**The `:new` clause of `assign_ai_translation/4` no longer assigns
`ai_endpoints`/`ai_prompts`/`ai_selected_*`/`ai_default_prompt_exists`
explicitly — this is safe, not a missing-assign crash.** It was the thing most
likely to be wrong in the diff. It delegates to
`assign_endpoint_prompt_state(socket, available?)`, whose `_false` clause routes
to `empty_endpoint_prompt_state/1`, which sets all five keys to exactly the
values the removed literals used. Every path through both clauses assigns them.

**`do_dispatch_ai/4` clause reordering is safe.** The bulk clause is guarded
`when scope in ["*", "**"]` — a binary, not a list — so moving the two
single-language clauses below it cannot shadow anything. The `lang == ""`
no-op clause still precedes the general binary clause, which is what matters.

**Every value-mode exit path messages the LiveView.** `translate_value_lang/3`
sends either `:translation_completed` or `:translation_failed`, and
`safe_translate_fields/2` converts a raise *or* a throw/exit into
`{:error, reason}`. A language that failed to report would stay in
`ai_in_flight` forever and block the form's save, so this matters. The one
uncovered case is an external kill of the task process (e.g. supervisor
shutdown), which no `rescue`/`catch` can intercept — acceptable, and the code
comments acknowledge it.

**Sinks cannot break request logging.** `dispatch_usage_sinks/1` wraps each
call in `try` with both `rescue` and `catch kind, reason`, *and* has a
function-level `rescue _ -> :ok`. The `with {:ok, request} <- result` in
`create_request/1` means a failed insert never reaches dispatch.

## Noted, not blocking

**"Nanodollar" is a misnomer for a misnomer.** The new comment on
`Request.cost_cents` says the unit is "NANODOLLARS — 1e-6 dollars". 1e-6 dollars
is a *micro*dollar; a nanodollar is 1e-9. The arithmetic the comment gives
(`cents = value ÷ 10_000`) is correct for 1e-6 dollars, and "nanodollars" is
already the established term throughout `tts_pricing.ex` (`cost_nanodollars/3`,
`@per_char_nanodollars_by_provider`, `@openai_nanodollars_per_minute`). So the
comment is consistent with the codebase and numerically right. Renaming the
concept would be a separate sweep across `tts_pricing.ex`'s public API — not
worth folding into a release whose purpose is the core 2.0 pin.

**Value-mode tasks outlive the LiveView.** `start_value_mode_tasks/5` uses
`Task.Supervisor.start_child/2`, which is unlinked, so a navigating-away user
leaves in-flight translations running to completion; the results `send/2` to a
dead pid and are discarded. This costs API spend for output nobody sees. It is
also arguably correct — the same translations would have been billed had the
user stayed — and matches the record-mode Oban path, which likewise doesn't
cancel on disconnect. Left as is.
