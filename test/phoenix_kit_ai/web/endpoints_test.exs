defmodule PhoenixKitAI.Web.EndpointsTest do
  use PhoenixKitAI.LiveCase

  describe "mount" do
    test "renders the endpoints list with the seeded endpoint", %{conn: conn} do
      fixture_endpoint(name: "Visible Endpoint")

      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints")
      assert html =~ "Visible Endpoint"
    end

    test "renders the empty/setup state with no endpoints", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints")
      # The LiveView swaps to the "setup" tab when there are no
      # endpoints. Either the setup copy or the empty endpoints heading
      # should be visible — assert against actual page content rather
      # than a tautology like `is_binary(html)`.
      assert html =~ ~r/setup|No endpoints/i
    end
  end

  describe "toggle_endpoint" do
    test "flipping enabled persists, surfaces a flash, and emits an activity row",
         %{conn: conn} do
      # Inject a scope so the LV's `actor_opts/1` threads `actor_uuid`
      # through to the activity log. Without this the test couldn't
      # distinguish a working actor-threading from a regression that
      # silently drops the keyword arg.
      scope = fake_scope()
      conn = put_test_scope(conn, scope)

      endpoint = fixture_endpoint(enabled: true)

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints")

      html =
        view
        |> element("button[phx-click='toggle_endpoint'][phx-value-uuid='#{endpoint.uuid}']")
        |> render_click()

      reloaded = PhoenixKitAI.get_endpoint!(endpoint.uuid)
      refute reloaded.enabled
      assert html =~ "Endpoint disabled"

      # Pin every threaded opt — `actor_uuid` proves the LV passed
      # `actor_opts(socket)` through; `metadata.name` proves the
      # log helper extracted the resource correctly; `actor_role`
      # confirms the role argument survived.
      assert_activity_logged(
        "endpoint.disabled",
        resource_uuid: endpoint.uuid,
        actor_uuid: scope.user.uuid,
        metadata_has: %{
          "name" => endpoint.name,
          "actor_role" => "user"
        }
      )
    end
  end

  describe "delete_endpoint" do
    test "removes the row, flashes success, and logs `endpoint.deleted`", %{conn: conn} do
      scope = fake_scope()
      conn = put_test_scope(conn, scope)

      endpoint = fixture_endpoint()

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints")

      html =
        view
        |> element("button[phx-click='delete_endpoint'][phx-value-uuid='#{endpoint.uuid}']")
        |> render_click()

      assert PhoenixKitAI.get_endpoint(endpoint.uuid) == nil
      assert html =~ "Endpoint deleted"

      assert_activity_logged(
        "endpoint.deleted",
        resource_uuid: endpoint.uuid,
        actor_uuid: scope.user.uuid,
        metadata_has: %{
          "name" => endpoint.name,
          "actor_role" => "user"
        }
      )
    end

    test "delete button declares phx-disable-with so a slow delete can't be double-clicked",
         %{conn: conn} do
      _endpoint = fixture_endpoint()

      {:ok, _view, html} = live(conn, "/en/admin/ai/endpoints")

      # Pin the C5 fix from the 2026-04-26 re-validation pass — matches
      # the canonical attribute regex used elsewhere in the suite.
      assert html =~ ~r/phx-click="delete_endpoint"[^>]+phx-disable-with/
    end
  end

  describe "handle_info catch-all" do
    test "ignores unrelated PubSub messages and logs at :debug", %{conn: conn} do
      # Lift the global Logger level to :debug for the duration of this
      # test — test config sets `level: :warning` which filters debug
      # messages BEFORE `capture_log` sees them. The `[level: :debug]`
      # opt on capture_log is the handler-level filter, not the global
      # one. Per workspace AGENTS.md "Logger.level must be lifted".
      previous_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      {:ok, view, _html} = live(conn, "/en/admin/ai/endpoints")

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          send(view.pid, :unknown_msg_from_another_module)
          send(view.pid, {:something_we_dont_care_about, %{}, %{}})

          # Render again — this is the LV's flush of pending messages.
          # If the catch-all is missing, this round-trip surfaces
          # FunctionClauseError. The `=~` assertion below proves the
          # page actually rendered (vs. is_binary which is true for any
          # error page too) AND that handle_info didn't break the LV.
          html = render(view)
          assert html =~ "AI Endpoints"
        end)

      # Pin the catch-all's Logger.debug — proves this branch fired
      # rather than the LV silently swallowing the message.
      assert log =~ "[PhoenixKitAI.Web.Endpoints] unhandled handle_info"
    end
  end
end
