defmodule PhoenixKitAI.Web.EndpointFormTest do
  use PhoenixKitAI.LiveCase

  alias PhoenixKitAI.Web.EndpointForm

  describe "new" do
    test "renders the create form with submit button + phx-disable-with", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints/new")

      # The submit button must declare phx-disable-with so a slow save
      # can't be double-submitted by accident — this was a HIGH finding
      # in PR #1's review.
      assert html =~ ~r/<button[^>]+type="submit"[^>]+phx-disable-with/

      # Page heading and form structure should be present.
      assert html =~ "New AI Endpoint"
      assert html =~ ~s(name="endpoint[name]")
    end
  end

  describe "edit" do
    test "renders the edit form with phx-disable-with on the submit button",
         %{conn: conn} do
      endpoint = fixture_endpoint(name: "Editable")

      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      assert html =~ "Editable"
      assert html =~ ~r/<button[^>]+type="submit"[^>]+phx-disable-with/
    end

    test "redirects with a translated error flash when the endpoint doesn't exist",
         %{conn: conn} do
      missing_uuid = "01234567-89ab-7def-8000-000000000000"

      assert {:error, {:live_redirect, %{flash: flash}}} =
               live(conn, "/en/admin/ai/endpoints/#{missing_uuid}/edit")

      assert flash["error"] =~ "Endpoint not found"
    end
  end

  describe "edit — legacy api_key recovery field" do
    # When the migration hasn't completed for this endpoint
    # (api_key column populated, integration_uuid still NULL), the
    # form surfaces the legacy key in a read-only password field with
    # a copy button so the operator can paste it into a new
    # Integration. Once an integration is selected and saved, the
    # changeset clears api_key in the same write so the field
    # disappears and stays gone.

    test "renders the recovery card when api_key is set and integration_uuid is nil",
         %{conn: conn} do
      endpoint = fixture_endpoint(api_key: "sk-or-recovery-test", integration_uuid: nil)

      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      assert html =~ "Legacy API key (recovery)"
      # Field is rendered with the legacy value (masked via type=password
      # client-side, but the value attr is in the markup so the copy
      # button can grab it).
      assert html =~ ~s(value="sk-or-recovery-test")
      assert html =~ "data-copy-target=\"#legacy-api-key-field\""
    end

    test "does NOT render the recovery card when integration_uuid is set",
         %{conn: conn} do
      %{uuid: integration_uuid} = seed_openrouter_connection("recovery-hidden")

      endpoint =
        fixture_endpoint(
          api_key: "sk-still-here-but-hidden",
          integration_uuid: integration_uuid
        )

      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      refute html =~ "Legacy API key (recovery)"
    end

    test "does NOT render the recovery card when api_key is the empty string",
         %{conn: conn} do
      # The post-clear state. `api_key` is NOT NULL in the schema, so
      # the changeset clears to "" rather than NULL — empty string is
      # treated as "no fallback" by every downstream consumer.
      endpoint = fixture_endpoint(api_key: "sk-temp")

      PhoenixKitAI.Test.Repo.query!(
        "UPDATE phoenix_kit_ai_endpoints SET api_key = '' WHERE uuid = $1",
        [Ecto.UUID.dump!(endpoint.uuid)]
      )

      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      refute html =~ "Legacy API key (recovery)"
    end

    test "is hidden after picking an integration and saving (clear-on-save round trip)",
         %{conn: conn} do
      # Pre-stage: an integration row to pick, plus a legacy endpoint.
      %{uuid: integration_uuid} = seed_openrouter_connection("clear-on-save")

      endpoint =
        fixture_endpoint(api_key: "sk-or-will-be-cleared", integration_uuid: nil)

      {:ok, view, html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")
      assert html =~ "Legacy API key (recovery)"

      # Simulate the integration_picker setting active_connection. The
      # form LV exposes "select_openrouter_connection" for this.
      view
      |> render_hook("select_openrouter_connection", %{"uuid" => integration_uuid})

      # Submit the form. The active_connection feeds integration_uuid
      # into the params via the form's save handler.
      view
      |> form("form[phx-submit=\"save\"]",
        endpoint: %{
          name: endpoint.name,
          provider: "openrouter",
          model: endpoint.model
        }
      )
      |> render_submit()

      # Reload from DB: api_key cleared, integration_uuid set, both
      # in the same transaction. Cleared to "" (not NULL) since the
      # column is NOT NULL — same end-state semantics for downstream.
      reloaded = PhoenixKitAI.get_endpoint!(endpoint.uuid)
      assert reloaded.integration_uuid == integration_uuid
      assert reloaded.api_key == ""

      # Recovery card no longer renders on a fresh mount.
      {:ok, _view2, html2} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")
      refute html2 =~ "Legacy API key (recovery)"
    end
  end

  describe "integration_warning/1" do
    # `save_success_message/2` calls `integration_warning/1` after a
    # successful save and appends the result to the flash. The flash
    # path is hard to drive end-to-end because the form's `provider`
    # is bound to the integration_picker's active_connection assign,
    # not a free-text input. Pinning the helper directly keeps the
    # branches honest.

    test "warns when nothing is configured (no integration_uuid, no provider, no api_key)" do
      # Pre-fix this returned nil because the function only knew about
      # `provider` and quietly skipped when it was empty. That hid the
      # "you saved a totally unconfigured endpoint" case from the
      # operator. Now the empty-everything endpoint surfaces the
      # "No integration configured" warning.
      result_nil = EndpointForm.integration_warning(%{provider: nil, api_key: nil})
      result_empty = EndpointForm.integration_warning(%{provider: "", api_key: nil})

      assert is_binary(result_nil)
      assert result_nil =~ "No integration configured"
      assert result_empty == result_nil
    end

    test "returns nil when there is a non-empty legacy api_key (fallback path works)" do
      result =
        EndpointForm.integration_warning(%{
          provider: "openrouter-not-set-up-#{System.unique_integer([:positive])}",
          api_key: "sk-or-v1-legacy"
        })

      assert result == nil
    end

    test "returns the warning string for a disconnected provider with no api_key" do
      provider = "openrouter-not-set-up-#{System.unique_integer([:positive])}"

      result =
        EndpointForm.integration_warning(%{
          provider: provider,
          api_key: nil
        })

      assert is_binary(result)
      assert result =~ "is not connected"
      assert result =~ provider
    end

    test "returns the warning when api_key is the empty string (treated as no fallback)" do
      provider = "openrouter-not-set-up-#{System.unique_integer([:positive])}"

      result =
        EndpointForm.integration_warning(%{
          provider: provider,
          api_key: ""
        })

      assert is_binary(result)
      assert result =~ "is not connected"
    end

    test "returns nil when integration_uuid resolves to a connected integration" do
      # Pre-warning fix, this branch was unreachable — the function
      # only checked `provider`. After the fix, integration_uuid takes
      # precedence and a connected pinned integration silences the
      # warning regardless of whatever `provider` still holds (it
      # defaults to the literal "openrouter" for new endpoints).
      %{uuid: uuid} =
        seed_openrouter_connection("warn-ok-#{System.unique_integer([:positive])}",
          data: %{"api_key" => "sk-test-warn", "status" => "connected"}
        )

      result =
        EndpointForm.integration_warning(%{
          integration_uuid: uuid,
          provider: "openrouter",
          api_key: nil
        })

      assert result == nil
    end

    test "returns the warning for a pinned integration that isn't connected" do
      # `integration_uuid` set but the row isn't reachable (deleted /
      # unreachable). With no api_key fallback, the request would
      # fail — surface that.
      stale_uuid = "01234567-89ab-7def-8000-000000warning"

      result =
        EndpointForm.integration_warning(%{
          integration_uuid: stale_uuid,
          provider: "openrouter",
          api_key: nil
        })

      assert is_binary(result)
      assert result =~ "selected integration is not connected"
    end

    test "returns nil when integration_uuid is unreachable but api_key fallback exists" do
      # Even with a broken pin, a stored legacy api_key keeps the
      # request working via OpenRouterClient.resolve_api_key/1's final
      # fallback. No warning needed.
      stale_uuid = "01234567-89ab-7def-8000-000000warning"

      result =
        EndpointForm.integration_warning(%{
          integration_uuid: stale_uuid,
          provider: "openrouter",
          api_key: "sk-or-v1-legacy"
        })

      assert result == nil
    end
  end

  describe "load_endpoint active_connection wiring" do
    # Pins upstream `3d8c0a6` ("form improvement"). The load helpers no
    # longer fall back to the literal string `"openrouter"` when no
    # integration matches, and the edit branch ignores stale
    # `endpoint.provider` UUIDs that don't point at a live connection.
    # Without these tests a regression to the old `"openrouter"` /
    # provider-trust semantics passes the rest of the suite silently.

    test "new endpoint with zero connections leaves active_connection nil",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.active_connection == nil
      assert assigns.integration_connected == false
    end

    test "new endpoint with exactly one connection still leaves picker empty",
         %{conn: conn} do
      # The picker mirrors the endpoint's actual stored state. A new
      # endpoint has no integration pinned, so the picker shows nothing
      # selected — even when only one connection exists. Auto-selecting
      # would mask "no integration set" with "an integration is set".
      seed_openrouter_connection("auto-#{System.unique_integer([:positive])}")

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.active_connection == nil
      assert assigns.selected_uuids == []
      assert assigns.integration_connected == false
    end

    test "edit endpoint whose provider matches a live connection keeps it",
         %{conn: conn} do
      %{uuid: uuid} =
        seed_openrouter_connection("match-#{System.unique_integer([:positive])}")

      endpoint = fixture_endpoint(provider: uuid)

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      assert :sys.get_state(view.pid).socket.assigns.active_connection == uuid
    end

    test "edit endpoint with stale provider + multiple connections falls to nil",
         %{conn: conn} do
      seed_openrouter_connection("a-#{System.unique_integer([:positive])}")
      seed_openrouter_connection("b-#{System.unique_integer([:positive])}")

      stale_uuid = "01234567-89ab-7def-8000-0000000abcde"
      endpoint = fixture_endpoint(provider: stale_uuid)

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.active_connection == nil
      # Edit branch's `active && Integrations.connected?(active)` short-circuits
      # to nil when active is nil; the new-endpoint branch uses explicit
      # `false`. Both are falsy — assert on truthiness, not the literal.
      refute assigns.integration_connected
    end

    test "edit endpoint with stale provider + exactly one connection leaves picker empty",
         %{conn: conn} do
      # Stale provider doesn't resolve, integration_uuid is nil, only
      # one other connection exists — the picker still shows nothing
      # selected. The endpoint isn't pinned to that connection, so
      # surfacing it as "selected" would be a lie.
      seed_openrouter_connection("solo-#{System.unique_integer([:positive])}")

      stale_uuid = "01234567-89ab-7def-8000-0000000abcde"
      endpoint = fixture_endpoint(provider: stale_uuid)

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.active_connection == nil
      assert assigns.selected_uuids == []
    end
  end

  describe "load_endpoint active_connection — integration_uuid path" do
    # Post-V107, endpoints reference the chosen integration via the
    # dedicated `integration_uuid` column. The picker should light up
    # the matching connection regardless of whatever the legacy
    # `provider` field still holds.

    test "edit endpoint with integration_uuid set picks the matching connection",
         %{conn: conn} do
      %{uuid: uuid} =
        seed_openrouter_connection("uuid-pinned-#{System.unique_integer([:positive])}")

      endpoint = fixture_endpoint(integration_uuid: uuid, provider: "openrouter")

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      assert :sys.get_state(view.pid).socket.assigns.active_connection == uuid
    end

    test "integration_uuid wins over a stale provider value", %{conn: conn} do
      %{uuid: real_uuid} =
        seed_openrouter_connection("winner-#{System.unique_integer([:positive])}")

      stale_provider = "01234567-89ab-7def-8000-0000000abcde"
      endpoint = fixture_endpoint(integration_uuid: real_uuid, provider: stale_provider)

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      assert :sys.get_state(view.pid).socket.assigns.active_connection == real_uuid
    end

    test "endpoint with deleted integration_uuid surfaces the orphan instead of auto-picking",
         %{conn: conn} do
      # Regression: when an endpoint's `integration_uuid` points at a
      # deleted integration AND there happens to be exactly one OTHER
      # current connection, the cond fall-through used to auto-select
      # that unrelated connection — silently switching the endpoint to
      # the wrong integration with no warning. Now `active` stays nil
      # for orphaned uuids and the picker renders its "Integration
      # deleted" warning card via `selected_uuids`.
      orphaned_uuid = "01234567-89ab-7def-8000-000000010001"

      # Seed a different integration so there's a "tempting" auto-pick
      # candidate available.
      %{uuid: live_uuid} =
        seed_openrouter_connection("decoy-#{System.unique_integer([:positive])}")

      endpoint = fixture_endpoint(integration_uuid: orphaned_uuid)

      {:ok, view, html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      assigns = :sys.get_state(view.pid).socket.assigns

      # `active_connection` is nil — we do NOT silently switch the
      # endpoint to the unrelated `live_uuid`.
      assert assigns.active_connection == nil
      refute assigns.active_connection == live_uuid

      # `selected_uuids` carries the orphan so the picker renders the
      # "Integration deleted" warning card.
      assert assigns.selected_uuids == [orphaned_uuid]

      # The warning text reaches the rendered HTML.
      assert html =~ "Integration deleted"
    end

    test "endpoint with deleted integration_uuid AND no other connections still surfaces orphan",
         %{conn: conn} do
      # No live connection at all — the picker should still render the
      # orphan warning, not just an empty state.
      orphaned_uuid = "01234567-89ab-7def-8000-000000020002"

      endpoint = fixture_endpoint(integration_uuid: orphaned_uuid)

      {:ok, view, html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.active_connection == nil
      assert assigns.selected_uuids == [orphaned_uuid]
      assert html =~ "Integration deleted"
    end
  end

  describe "select_openrouter_connection event" do
    # The picker dispatches this event with the chosen integration's
    # uuid. The form should write it into `form.params` under
    # `integration_uuid` (not `provider`) so save persists the new
    # column. Pins the Phase 3a swap.

    test "writes the picked uuid into form.params['integration_uuid']",
         %{conn: conn} do
      %{uuid: uuid} =
        seed_openrouter_connection("pick-#{System.unique_integer([:positive])}")

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")

      view
      |> element(~s(button[phx-click="select_openrouter_connection"][phx-value-uuid="#{uuid}"]))
      |> render_click()

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.active_connection == uuid
      assert assigns.form.params["integration_uuid"] == uuid
    end

    test "clicking the selected card again deselects it",
         %{conn: conn} do
      # The picker emits action="deselect" when the currently-selected
      # card is clicked. The form should clear active_connection,
      # selected_uuids, and write nil into form.params so save
      # persists the unpinning instead of silently re-using the
      # previously-stamped value.
      %{uuid: uuid} =
        seed_openrouter_connection("toggle-#{System.unique_integer([:positive])}")

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")

      # Pick it.
      view
      |> render_hook("select_openrouter_connection", %{
        "uuid" => uuid,
        "action" => "select"
      })

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.active_connection == uuid
      assert assigns.selected_uuids == [uuid]
      assert assigns.form.params["integration_uuid"] == uuid

      # Click it again — the picker emits action="deselect".
      view
      |> render_hook("select_openrouter_connection", %{
        "uuid" => uuid,
        "action" => "deselect"
      })

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.active_connection == nil
      assert assigns.selected_uuids == []
      assert assigns.integration_connected == false
      assert assigns.form.params["integration_uuid"] == nil
    end

    test "deselect on an existing endpoint clears integration_uuid on save",
         %{conn: conn} do
      # Edit an endpoint that's pinned to a connection, deselect via
      # the picker, save — the DB row should end up with
      # integration_uuid = nil (not the original uuid).
      %{uuid: integration_uuid} =
        seed_openrouter_connection("clear-on-save-#{System.unique_integer([:positive])}")

      endpoint = fixture_endpoint(integration_uuid: integration_uuid, provider: "openrouter")

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/#{endpoint.uuid}/edit")

      # Sanity: load_endpoint resolved the pin.
      assert :sys.get_state(view.pid).socket.assigns.active_connection == integration_uuid

      view
      |> render_hook("select_openrouter_connection", %{
        "uuid" => integration_uuid,
        "action" => "deselect"
      })

      view |> form("form", endpoint: %{name: endpoint.name}) |> render_submit()

      reloaded = PhoenixKitAI.get_endpoint!(endpoint.uuid)
      assert reloaded.integration_uuid == nil
    end
  end

  describe "handle_info catch-all" do
    test "ignores unrelated PubSub messages without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")

      send(view.pid, :unknown_msg_from_another_module)
      send(view.pid, {:something_we_dont_care_about, %{}, %{}})

      assert is_binary(render(view))
    end
  end

  describe "edge-case input handling" do
    # These pin C12 agent #2's "tests cover error paths, not just happy
    # paths" requirement. Each case is a class of input that has
    # historically tripped Phoenix forms or Ecto changesets.

    test "Unicode name round-trips through changeset + DB", _ do
      attrs = %{
        name: "日本語エンドポイント — Café 🚀 #{System.unique_integer([:positive])}",
        provider: "openrouter",
        model: "a/b",
        api_key: "sk-test-key"
      }

      assert {:ok, endpoint} = PhoenixKitAI.create_endpoint(attrs)
      assert endpoint.name =~ "日本語"
      assert endpoint.name =~ "🚀"

      reloaded = PhoenixKitAI.get_endpoint!(endpoint.uuid)
      assert reloaded.name == endpoint.name
    end

    test "SQL metacharacters in name don't break create_endpoint or get_endpoint", _ do
      malicious =
        "'; DROP TABLE phoenix_kit_ai_endpoints; -- #{System.unique_integer([:positive])}"

      assert {:ok, endpoint} =
               PhoenixKitAI.create_endpoint(%{
                 name: malicious,
                 provider: "openrouter",
                 model: "a/b",
                 api_key: "sk-test-key"
               })

      # Round-trip — the literal string lives in the DB; Ecto's
      # parameterised query path makes injection a non-issue.
      assert endpoint.name == malicious
      assert PhoenixKitAI.get_endpoint!(endpoint.uuid).name == malicious
    end

    test "name longer than 100 chars is rejected by the changeset validator" do
      too_long = String.duplicate("X", 101)

      changeset =
        PhoenixKitAI.Endpoint.changeset(%PhoenixKitAI.Endpoint{}, %{
          name: too_long,
          provider: "openrouter",
          model: "a/b"
        })

      refute changeset.valid?

      assert changeset.errors[:name] |> elem(0) =~ "should be at most"
    end

    test "empty name on the validate event renders an inline error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints/new")

      # `phx-change="validate"` fires on every keystroke. The form body
      # has a hidden `endpoint[model]` input that must match what the
      # LV rendered, so we trigger validate via render_change with the
      # field we actually want to vary, leaving the model alone.
      html =
        view
        |> render_change("validate", %{
          "endpoint" => %{"name" => "", "provider" => "openrouter", "model" => ""}
        })

      # Inline error renders because the LV's validate event sets
      # `:action = :validate` (endpoint_form.ex:236, 300, 324, 343),
      # gating `<.input>`'s error display.
      assert html =~ "can&#39;t be blank" or html =~ "blank"
    end
  end
end
