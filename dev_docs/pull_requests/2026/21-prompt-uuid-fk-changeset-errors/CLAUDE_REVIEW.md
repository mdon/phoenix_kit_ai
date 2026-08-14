# PR #21 Review — Catch `prompt_uuid` foreign key violations as changeset errors

**Author:** Max Don (mdon)
**Reviewed:** 2026-08-14 (ecosystem sweep)
**Verdict:** APPROVED — merged, with one gate fix and three unrelated stale tests repaired

---

## The change

`Request.changeset/2` declared no `foreign_key_constraint` for `prompt_uuid`, so a
request referencing a missing prompt raised `Ecto.ConstraintError` — a 500 where a
changeset error belongs. Its two siblings already had explicit `:name` options.

It declares **both** candidate names, which is correct and worth keeping even though
it looks redundant:

```elixir
|> foreign_key_constraint(:prompt_uuid, name: :fk_ai_requests_prompt_uuid)
|> foreign_key_constraint(:prompt_uuid, name: :phoenix_kit_ai_requests_prompt_uuid_fkey)
```

Core's v135 adds this FK twice under two names, each block guarded only by its own
name, so which one an install carries depends on when it was migrated. I confirmed
both are present on this workspace's migrated database:

```
fk_ai_requests_prompt_uuid                 FOREIGN KEY (prompt_uuid) REFERENCES phoenix_kit_ai_prompts(uuid) ON DELETE SET NULL
phoenix_kit_ai_requests_prompt_uuid_fkey   FOREIGN KEY (prompt_uuid) REFERENCES phoenix_kit_ai_prompts(uuid) ON DELETE SET NULL
```

Ecto matches by name and Postgres reports exactly one `conname` per violation, so the
name that exists matches and the other is inert — no double error.

**This gets better, not worse, with core 2.4.0.** Core's new V169 (shipped in the same
sweep) drops `fk_ai_requests_prompt_uuid` and keeps the legacy `_fkey` — precisely
because that is what the installed base carries. The dual declaration was already
correct for that convergence and needs no follow-up here.

---

## Findings

### BUG - MEDIUM — the PR failed this repo's own gate *(fixed on main)*

`mix precommit` exits non-zero on the new line in `coverage_test.exs`:

```
[D] ↘ Nested modules could be aliased at the top of the invoking module.
      test/phoenix_kit_ai/coverage_test.exs:666:19
```

`PhoenixKit.Test.Fixtures.confirmed_user_fixture()` was called fully qualified.
Aliased at the top of the module instead, matching the file's existing
`alias PhoenixKitAI.{Endpoint, Prompt, Request}`.

The substance of that change is right, and its comment is worth keeping: `user_uuid`
carries a real FK, so once the declaration matches the constraint, a made-up UUID
returns a changeset error rather than raising — which the fixture's `{:ok, r} = …`
would have turned into a `MatchError`.

---

## Unrelated: this suite had been red for three releases

Not from this PR, but found by running it — and fixed here rather than released
around, since the repo was about to publish with a failing suite:

1. **`tts_test.exs` — "returns only :audio and :format".** `:timestamps` joined
   `speak/3`'s public shape in **0.16.0** (`ac7c4e4`, xAI `with_timestamps`) and is in
   the function's own `@spec`; the assertion was never updated. Now asserts all three
   keys and pins `timestamps` to `nil` for a non-xAI provider, so the test still says
   something about *this* endpoint rather than just widening to fit.

2. **`tts_test.exs` — `assert is_nil(row.cost_cents)`.** TTS cost stopped being nil in
   **0.15.0** (`7809906`), when it began being estimated from `TtsPricing`'s rate
   table — the implementation comment says so explicitly. Now asserts a positive
   integer *and* cross-checks it against `TtsPricing.cost_nanodollars/3`, so the test
   pins the estimate rather than merely tolerating it.

3. **`image_generation_test.exs` — "an explicit caller :size/:quality overrides the
   stored default".** The test passed only `size:` and then asserted `quality` was
   *not* the endpoint's stored `"hd"` — i.e. it demanded a stored default vanish
   because an unrelated option was overridden. The code was right and the test was
   wrong. It now passes both options and asserts both override, which is what the name
   claims.

All three were verified pre-existing by re-running them against core **2.3.0** with
the old lockfile: same 3 failures, so neither this PR nor the core 2.4.0 upgrade
caused them.

**Worth acting on separately:** nothing catches this. The repo's `precommit` does not
run `mix test`, and `.github/workflows` does not run it on push either, so a stale
test can sit red across several releases without surfacing. That is the actual defect
behind all three.

---

## Verified against core 2.4.0

- `mix deps.update --all` → `phoenix_kit 2.3.0 => 2.4.0`, resolved from Hex.
- `mix precommit` → exit 0 (compile `--warnings-as-errors`, `deps.unlock --check-unused`,
  `hex.audit`, format, credo `--strict`, dialyzer).
- `mix test` → **907 tests, 0 failures** against real PostgreSQL.
