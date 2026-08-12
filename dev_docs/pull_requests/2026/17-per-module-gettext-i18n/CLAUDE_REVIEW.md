# Claude Review — PR #17 (per-module Gettext i18n) and PR #18 (test DB from env)

Reviewed 2026-08-12 as part of the ecosystem PR sweep. Both PRs merged into
`main`; findings below were applied as follow-up commits on `main`, not as
change requests.

**Verdict: both APPROVED.** One production defect found — unrelated to either
PR's own changes, but surfaced by PR #18 — and fixed. Two test defects also
surfaced by PR #18 are left open with reasons.

## PR #18 — Read test DB name and pool size from the environment

Scope is `config/test.exs` plus an `AGENTS.md` note. Verified against
`phoenix_kit` core's own `config/test.exs`: the `pg_test_db` / `pg_test_pool`
helpers are character-for-character the same mechanism, including the detail
that matters most — both read through a `case` on `System.get_env/1` rather
than `System.get_env/2`, because the two-arity form falls back only when the
variable is *unset*. A set-but-empty `PGPOOL=` (trivial to produce from a
shell, or from `PGPOOL:` with no value in YAML) yields `""`, which
`System.get_env/2` happily returns and `Integer.parse/1` then chokes on,
aborting config loading with an `ArgumentError` that never names the variable.
The `case` avoids that.

Defaults are unchanged when both variables are unset, so Hex CI and a plain
local `mix test` behave exactly as before. Nothing further to fix here.

The PR's own description is unusually valuable: it lists the five stable
failures that running the previously-excluded 545 integration tests turns up.
Those are treated as review findings below.

## PR #17 — Per-module Gettext i18n (en/ru/et)

A large but disciplined retrofit. The parts worth recording:

**The backend switch is complete.** The failure mode for this kind of change is
a file left bound to core's `PhoenixKitWeb.Gettext`, which then silently looks
its msgids up in core's catalogue and renders English no matter the locale.
Audited every file in `lib/` containing a `gettext`/`ngettext` call: 15 files,
of which 10 are `.ex` — all 10 carry `use Gettext, backend: PhoenixKitAI.Gettext`
— and 5 are `.heex`, each compiled in the context of a co-located LiveView
module that carries it. No file is left on core's backend.

The positional hazard the PR documents in `AGENTS.md` (a `gettext` call written
*above* the `use` line binds to core's catalogue) is real and correctly
avoided: in every file the `use` sits in the module header, above all call
sites.

**The catalogues are mechanically sound.** Parsed all three `.po` files and
checked the properties that break at runtime rather than merely reading oddly:

| Check | en | et | ru |
|---|---|---|---|
| Entries | 338 | 338 | 338 |
| `fuzzy`-flagged | 0 | 0 | 0 |
| Empty `msgstr` | 0 | 0 | 0 |
| `%{...}` placeholder mismatch vs. msgid | 0 | 0 | 0 |

Placeholder mismatch is the one that would bite users: a `msgstr` referencing a
binding the call site never passes degrades to the raw msgid at runtime. There
are none. Plural handling is correct too — 6 plural msgids per locale, with
`nplurals=3` and a full set of `msgstr[2]` entries in ru, `nplurals=2` in
en/et.

**`translatable_labels/0` is the right fix** for the tab-label problem, and the
`@doc` explaining it is worth keeping. `admin_tabs/0` and
`permission_metadata/0` declare labels as plain string literals, which
`mix gettext.extract` cannot see (it scans for macro calls, not struct
fields). Hand-maintaining those five entries in the `.pot` would have worked
until the next `mix gettext.merge`, which deletes any `.po` entry absent from a
freshly built `.pot`. Anchoring them with `dgettext_noop/2` makes extraction
find them for real. The `"Usage"` case is the subtle one and the PR caught it:
it was present in the `.pot` only by coincidence, via an unrelated
`gettext("Usage")` in `web/prompts.ex` — reword that call and the tab would
have reverted to English with no compile error and no failing test.

**Two genuine bugs fixed in passing**, both the same shape — a translated
string with a raw English word stitched into it, which no catalogue can ever
translate:

- `endpoint_form.ex` interpolated the literal `"created"`/`"updated"` into
  `gettext("Endpoint %{action} successfully")`. Now two separate literal
  `gettext` calls dispatched on an atom.
- `ai_translate.ex` interpolated `"language"`/`"languages"` via a hand-rolled
  `ngettext_plural/3` helper that hardcoded the English two-form rule — so
  Russian's three plural forms were unreachable by construction. Now a real
  `ngettext/3` call and the helper is deleted.

No red flags against the Phoenix skill's checklist: no queries added to
`mount/3`, no PubSub topics touched, no `terminate/2` or `start_async` usage
introduced.

## Finding — FK constraints could never match (fixed on `main`)

**This is a production defect, not a test problem**, and it predates both PRs.
PR #18's description reports it as a test failure at `coverage_test.exs:660`;
the underlying cause is in shipped code.

`Request.changeset/2` ended with:

```elixir
|> foreign_key_constraint(:endpoint_uuid)
|> foreign_key_constraint(:user_uuid)
```

Without an explicit `:name`, `foreign_key_constraint/2` derives the Postgres
default name `phoenix_kit_ai_requests_<field>_fkey`. Core's migration chain
names them differently. Enumerating every constraint core creates on this
table:

```
phoenix_kit_ai_requests_pkey
fk_ai_requests_endpoint_uuid
fk_ai_requests_prompt_uuid
fk_ai_requests_user_uuid
phoenix_kit_ai_requests_prompt_uuid_fkey
```

`endpoint_uuid` and `user_uuid` exist **only** under the `fk_ai_requests_*`
names. The derived names appear nowhere, so neither constraint declaration
could ever match a real violation, and both lines were dead code. A request
logged against a since-deleted endpoint or user raised a raw
`Ecto.ConstraintError` out of `create_request/1` instead of returning
`{:error, changeset}`.

Fixed on `main` by pinning the names:

```elixir
|> foreign_key_constraint(:endpoint_uuid, name: :fk_ai_requests_endpoint_uuid)
|> foreign_key_constraint(:user_uuid, name: :fk_ai_requests_user_uuid)
```

The change is strictly an improvement in the live path: every internal caller
(`log_request/7` and the `log_*_request/6` helpers in `phoenix_kit_ai.ex`)
passes the result of `create_request/1` straight through without matching on
`{:ok, _}`, so an error tuple is discarded harmlessly where the exception
previously propagated up through the completion call.

Locked in by a new test in `schema_coverage_test.exs` that reads the registered
constraint names off the changeset struct. It asserts both names positively and
also asserts that *no* FK constraint on this changeset carries a derived
`*_fkey` name — so re-adding a bare `foreign_key_constraint/1` for any field
fails the suite. It needs no database, so unlike the integration test that
surfaced the bug, it runs everywhere.

### Related, not fixed here: core creates `prompt_uuid`'s FK twice

Core adds both `fk_ai_requests_prompt_uuid` and
`phoenix_kit_ai_requests_prompt_uuid_fkey` for the same column — two
equivalent foreign keys where one is intended. `Request.changeset/2` declares
no constraint for `prompt_uuid` at all, so nothing here is broken today, but
adding one would have to guess which of the two duplicates Postgres reports on
violation.

Left alone deliberately: the fix belongs in `phoenix_kit` core's migration
chain, not in this module's changeset, and core had no PR open in this sweep.
Worth raising against core separately.

## Findings not fixed — test defects surfaced by PR #18

The environment this sweep ran in has no Postgres, so the 545 integration tests
stayed excluded here and none of the below could be verified against a live
database. Editing them blind is how a test gets "fixed" into a different kind
of wrong, so they are left open and recorded instead.

- **`coverage_test.exs:660`** — `filter by :user_uuid restricts to that user`
  inserts a request with `Ecto.UUID.generate()` as `user_uuid`, referencing a
  user row that was never created. That violates a real FK regardless of the
  constraint-name fix above; the fix only changes the failure from
  `Ecto.ConstraintError` to a `MatchError` on the fixture's `{:ok, r} =`. The
  test needs a genuine `phoenix_kit_users` row, and this repo has no user
  fixture — `live_case.ex`'s `fake_scope/1` builds a plain map that is never
  inserted. Writing one means depending on core's user-creation API and
  verifying it against a database.
- **`tts_test.exs:105`** — `speak/3` returns an unexpected `:timestamps` key
  (`[:audio, :format, :timestamps]` vs. an expected `[:audio, :format]`).
  Needs a call against a real provider stub to tell a product regression apart
  from a stale assertion.
- **`tts_test.exs:165`** — a TTS success log row carries a non-nil
  `cost_cents` where the test expects `nil`. Same reasoning; `tts_pricing.ex`
  may legitimately price TTS now.
- **`image_generation_test.exs:260`** — agreed with the PR author's read: this
  is test debt, not a product defect. The test is titled "an explicit caller
  `:size`/`:quality` overrides the stored default" but only ever passes
  `size:`. `maybe_put_default_opt/3` checks `Keyword.has_key?(opts, key)` and
  fills the stored default only when the caller omitted the option, so
  precedence is correct and the request body rightly carries the endpoint's
  stored `quality: "hd"`. The test needs a `quality:` override added to match
  its own name.
- **`playground_voice_test.exs:87`** — a `RealtimeMock.send_text_done/1`
  expectation is set but never invoked.
- **Intermittent**, seen in one of the author's two runs but not the other:
  `prompts_test.exs:77` and `endpoints_test.exs:199`, both asserting a delete
  button's rendered HTML carries `phx-disable-with` immediately after
  `phx-click`. Assertion is order-sensitive on attribute rendering; likely
  fragile rather than a data bug.

These are follow-up work for an environment with a database attached, and are
listed in the release CHANGELOG entry's scope only insofar as the FK fix goes.
