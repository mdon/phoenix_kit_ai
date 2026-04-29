defmodule PhoenixKitAI.DestructiveRescueTest do
  @moduledoc """
  Coverage for rescue/recovery branches that require a destructive
  DROP TABLE inside the test transaction.

  These tests share schema-level resources with the rest of the suite,
  so they MUST run `async: false` to avoid deadlock against parallel
  async tests holding row locks on the same tables. Sandbox rolls back
  the DROP at test exit, leaving the schema intact for subsequent
  test files.

  Each test exercises a `rescue _ -> ...` / `catch :exit, _ -> ...`
  clause that would otherwise be unreachable without an in-process DB-
  error injection (which we don't have, since we deliberately don't
  pull in Mox).

  Workspace AGENTS.md "Coverage push pattern #4" — drop tables to
  exercise rescues. Canonical reference:
  `phoenix_kit_locations/test/destructive_rescue_test.exs`.
  """

  use PhoenixKitAI.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  describe "enabled?/0 — DB error swallowing" do
    test "returns false when phoenix_kit_settings table is missing (rescue branch)" do
      # Pin the `rescue _ -> false` clause of `enabled?/0`. Core's
      # `Settings.get_boolean_setting/2` raises Postgrex.Error
      # `:undefined_table` when the settings table is dropped; our
      # rescue catches it and returns false (the expected fallback
      # for "AI is not enabled" / "DB unhealthy").

      # Confirm the function works first (control).
      _ = PhoenixKitAI.enabled?()

      SQL.query!(TestRepo, "DROP TABLE phoenix_kit_settings CASCADE")

      assert PhoenixKitAI.enabled?() == false
    end
  end

  describe "safe_count/1 — DB error swallowing in get_config" do
    test "get_config/0 returns zeroed counts when the underlying tables are missing" do
      # Pin the `rescue _ -> 0` clause of `safe_count/1`. Three of
      # the four config fields go through safe_count
      # (endpoints_count / total_requests / total_tokens). Drop all
      # three source tables; safe_count catches the resulting
      # Postgrex.Error and returns 0.

      SQL.query!(TestRepo, "DROP TABLE phoenix_kit_ai_requests CASCADE")
      SQL.query!(TestRepo, "DROP TABLE phoenix_kit_ai_endpoints CASCADE")
      SQL.query!(TestRepo, "DROP TABLE phoenix_kit_ai_prompts CASCADE")

      config = PhoenixKitAI.get_config()

      # `enabled` may be true or false depending on settings table state;
      # the load-bearing assertion is on the safe_count fallbacks.
      assert config.endpoints_count == 0
      assert config.total_requests == 0
      assert config.total_tokens == 0
    end
  end

end
