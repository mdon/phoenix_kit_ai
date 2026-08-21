# Grok Review — PR #22 "Match core's headerless multilang tabs, and fix a racy voice test"

**Merge commit:** d146d59
**Author:** mdon (fix/multilang-tabs-defaults-and-voice-race)
**Files:** `lib/phoenix_kit_ai/components/ai_translate.ex`, `test/phoenix_kit_ai/ai_multilang_tabs_test.exs`, `test/phoenix_kit_ai/web/playground_voice_test.exs`

## Summary of the change

Two independent fixes:

1. `<.ai_multilang_tabs>` declared its own `show_header` / `show_info` defaults
   as `true`, while core's `<.multilang_tabs>` flipped them to `false` on
   2026-08-15. The wrapper does not inherit core's attr defaults, so every
   AI-enabled form kept a "Content Language" header row that every other form
   had lost. Defaults now match core; an explicit `show_header={true}` still
   renders the row. Tests pin both.

2. The playground voice test expected `Session.send_text/2` and `finish/1`
   (GenServer casts) to have been consumed before `verify_on_exit!`. The
   LiveView handler returns as soon as the casts are sent, so the mock
   intermittently reported "invoked 0 times". The mocks now signal the test
   process; `assert_receive` both synchronises and asserts.

Verified: in-repo callers of `ai_multilang_tabs` (catalogue, publishing,
projects) do not pass `show_header`, so they pick up the new default. That is
the product call, not a silent regression.

## Findings

### 1. NITPICK — delete-button tests assumed HEEx attribute order

Two existing tests (`prompts_test`, `endpoints_test`) required
`phx-click="delete_*"` to appear *before* `phx-disable-with` on the same
tag. Core's `table_row_menu_button` dumps rest attrs after `class`, and
HEEx may emit `phx-disable-with` first — the pin then fails against an
otherwise-correct button. Surfaced by the core 2.13.5 bump, not by this
PR. **Fixed:** pin the two attributes independently, with
`phx-disable-with="…Deleting"` so toggle's "Updating" cannot match.
