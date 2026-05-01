defmodule PhoenixKitAI.Web.EndpointForm do
  @moduledoc """
  LiveView for creating and editing AI endpoints.

  An endpoint combines provider credentials, model selection, and generation
  parameters into a single configuration.
  """

  use PhoenixKitWeb, :live_view

  require Logger

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Events, as: IntegrationEvents
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitAI, as: AI
  alias PhoenixKitAI.AIModel
  alias PhoenixKitAI.Endpoint
  alias PhoenixKitAI.OpenRouterClient

  # ===========================================
  # FUNCTION COMPONENTS
  # ===========================================

  attr(:key, :string, required: true)
  attr(:definition, :map, required: true)
  attr(:form, :map, required: true)
  attr(:endpoint, :any, default: nil)
  attr(:selected_model, :map, default: nil)
  attr(:size, :string, default: "md")

  def param_input(assigns) do
    field = assigns.definition.field
    field_str = Atom.to_string(field)
    current_value = resolve_current_value(assigns, field, field_str)

    assigns =
      assigns
      |> assign(:field, field)
      |> assign(:field_str, field_str)
      |> assign(:current_value, current_value)
      |> assign(:input_class, size_class(assigns.size, "input"))
      |> assign(:textarea_class, size_class(assigns.size, "textarea"))

    ~H"""
    <div class="form-control">
      <label class="label">
        <span class={if @size == "sm", do: "label-text", else: "label-text font-medium"}>
          {@definition.label}
        </span>
      </label>

      <%= case @definition.type do %>
        <% :float -> %>
          <input
            type="number"
            name={"endpoint[#{@field_str}]"}
            value={@current_value}
            class={@input_class}
            step={@definition[:step] || 0.1}
            min={@definition[:min]}
            max={@definition[:max]}
            placeholder={@definition[:placeholder]}
          />
        <% :integer -> %>
          <input
            type="number"
            name={"endpoint[#{@field_str}]"}
            value={@current_value}
            class={@input_class}
            min={@definition[:min]}
            max={get_max_for_field(@field_str, @definition, @selected_model)}
            placeholder={get_placeholder_for_field(@field_str, @definition, @selected_model)}
          />
        <% :string_list -> %>
          <textarea
            name={"endpoint[#{@field_str}]"}
            class={@textarea_class}
            rows="2"
            placeholder={@definition[:placeholder] || "One per line"}
          >{@current_value}</textarea>
        <% _ -> %>
          <input
            type="text"
            name={"endpoint[#{@field_str}]"}
            value={@current_value}
            class={@input_class}
            placeholder={@definition[:placeholder]}
          />
      <% end %>
    </div>
    """
  end

  defp resolve_current_value(assigns, field, field_str) do
    value =
      assigns.form.params[field_str] ||
        (assigns.endpoint && Map.get(assigns.endpoint, field)) ||
        assigns.definition[:default] ||
        ""

    case {assigns.definition.type, value} do
      {:string_list, list} when is_list(list) -> Enum.join(list, "\n")
      _ -> value
    end
  end

  defp size_class("sm", "input"), do: "input input-bordered input-sm"
  defp size_class(_, "input"), do: "input input-bordered"
  defp size_class("sm", "textarea"), do: "textarea textarea-bordered textarea-sm"
  defp size_class(_, "textarea"), do: "textarea textarea-bordered"

  defp get_max_for_field("max_tokens", _definition, selected_model) do
    selected_model && selected_model.max_completion_tokens
  end

  defp get_max_for_field(_field, definition, _selected_model) do
    definition[:max]
  end

  defp get_placeholder_for_field("max_tokens", _definition, selected_model) do
    if selected_model && selected_model.max_completion_tokens do
      "Max: #{selected_model.max_completion_tokens}"
    else
      "Model default"
    end
  end

  defp get_placeholder_for_field(_field, definition, _selected_model) do
    definition[:placeholder]
  end

  # ===========================================
  # LIFECYCLE
  # ===========================================

  @impl true
  def mount(_params, _session, socket) do
    # No DB queries in mount/3 — they run twice. The `enabled?` check,
    # integration listing, and endpoint load all happen in
    # `handle_params/3`.
    if connected?(socket), do: IntegrationEvents.subscribe()

    socket =
      socket
      |> assign(:project_title, nil)
      |> assign(:current_path, Routes.path("/admin/ai"))
      |> assign(:provider_connections, [])
      |> assign(:current_provider, "openrouter")
      |> assign(:models, [])
      |> assign(:models_grouped, [])
      |> assign(:models_loading, false)
      |> assign(:models_loading_slow, false)
      |> assign(:model_fetch_slow_timer, nil)
      |> assign(:models_error, nil)
      |> assign(:selected_model, nil)
      |> assign(:selected_provider, nil)
      |> assign(:provider_models, [])
      |> assign(:endpoint, nil)
      |> assign(:active_connection, nil)
      |> assign(:selected_uuids, [])
      |> assign(:integration_connected, false)
      |> assign(:form, to_form(AI.change_endpoint(%Endpoint{})))
      |> assign(:page_title, "AI Endpoint")
      |> assign(:loaded_id, :unloaded)

    {:ok, socket}
  end

  defp load_endpoint(socket, nil) do
    # New endpoint: nothing is pre-selected. The picker reflects the
    # endpoint's actual state (no integration yet), so the operator
    # explicitly picks one. Auto-selecting a single available connection
    # would mask "no integration set" with "an integration is set" and
    # confuse anyone scanning the form to verify wiring.
    socket
    |> assign(:page_title, "New AI Endpoint")
    |> assign(:endpoint, nil)
    |> assign(:form, to_form(AI.change_endpoint(%Endpoint{})))
    |> assign(:active_connection, nil)
    |> assign(:selected_uuids, [])
    |> assign(:integration_connected, false)
  end

  defp load_endpoint(socket, id) do
    case AI.get_endpoint(id) do
      nil ->
        socket
        |> put_flash(:error, gettext("Endpoint not found"))
        |> push_navigate(to: Routes.ai_path())

      endpoint ->
        changeset = AI.change_endpoint(endpoint)
        connections = socket.assigns.provider_connections

        # Resolve the picker's `active_connection` from the endpoint's
        # `integration_uuid`. Fall back to the legacy `provider` field
        # (which carried the uuid before the dedicated column existed)
        # so endpoints that pre-date V107's backfill still light up the
        # right picker entry.
        #
        # The picker reflects the endpoint's actual stored state — it
        # never auto-picks a connection the endpoint isn't pinned to.
        # When `integration_uuid` is set but unresolvable, the orphan
        # uuid flows through `selected_uuids` so the picker renders its
        # "Integration deleted" warning card. When nothing is pinned,
        # `active` stays nil and the picker shows no selection — the
        # operator picks one explicitly.
        {active, orphaned_integration_uuid} =
          cond do
            endpoint.integration_uuid &&
                Enum.any?(connections, &(&1.uuid == endpoint.integration_uuid)) ->
              {endpoint.integration_uuid, nil}

            endpoint.integration_uuid ->
              # Set but unresolvable — surface the orphan.
              {nil, endpoint.integration_uuid}

            endpoint.provider && Enum.any?(connections, &(&1.uuid == endpoint.provider)) ->
              {endpoint.provider, nil}

            true ->
              {nil, nil}
          end

        connected = active && Integrations.connected?(active)

        # `selected_uuids` is what the picker renders as selected.
        # When `active` resolves cleanly, it's just `[active]`. When
        # the original integration is deleted, we pass the orphan uuid
        # so the picker can render its "Integration deleted" warning
        # alongside the other connection cards.
        selected_uuids =
          cond do
            active -> [active]
            orphaned_integration_uuid -> [orphaned_integration_uuid]
            true -> []
          end

        socket =
          socket
          |> assign(:page_title, "Edit AI Endpoint")
          |> assign(:endpoint, endpoint)
          |> assign(:form, to_form(changeset))
          |> assign(:active_connection, active)
          |> assign(:selected_uuids, selected_uuids)
          |> assign(:integration_connected, connected)
          |> assign(:current_provider, endpoint.provider)

        # Load models if integration is connected
        if connected do
          send(self(), :fetch_models_from_integration)
          start_model_fetch_indicators(socket)
        else
          socket
        end
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    # `:loaded_id` tracks which `params["id"]` the LV currently has data
    # for. `:unloaded` is the initial sentinel set in `mount/3`; `nil`
    # means "loaded as the new-endpoint form"; a binary UUID means
    # "loaded for that endpoint". Re-loads only when the id actually
    # changes — handles the `push_patch` case where the same LV process
    # is reused across `/endpoints/A/edit` → `/endpoints/B/edit` (no
    # caller does this today, but cheap to be safe for future routes).
    if socket.assigns.loaded_id == params["id"] do
      {:noreply, socket}
    else
      handle_initial_params(params, socket)
    end
  end

  defp handle_initial_params(params, socket) do
    if AI.enabled?() do
      socket =
        socket
        |> assign(:project_title, Settings.get_project_title())
        |> assign(:provider_connections, load_all_provider_connections())
        |> load_endpoint(params["id"])
        |> assign(:loaded_id, params["id"])

      {:noreply, socket}
    else
      {:noreply,
       socket
       |> put_flash(:error, gettext("AI module is not enabled"))
       |> push_navigate(to: Routes.path("/admin/modules"))}
    end
  end

  @impl true
  def handle_event("validate", %{"endpoint" => params}, socket) do
    # When the operator changes the provider dropdown, the previously
    # picked integration is for a different provider — clear it so the
    # picker doesn't render an off-provider uuid as orphaned. Also nil
    # out base_url so the changeset's `maybe_set_default_base_url`
    # picks up the new provider's default URL.
    {params, socket} = maybe_handle_provider_change(params, socket)

    changeset =
      (socket.assigns.endpoint || %Endpoint{})
      |> AI.change_endpoint(params)
      |> Map.put(:action, :validate)

    # Update selected model when model changes
    selected_model =
      case params["model"] do
        nil -> socket.assigns.selected_model
        "" -> nil
        model_id -> find_model(socket.assigns.models, model_id)
      end

    socket =
      socket
      |> assign(:form, to_form(changeset))
      |> assign(:selected_model, selected_model)
      |> assign(:current_provider, params["provider"] || socket.assigns[:current_provider])

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_provider", %{"provider" => ""}, socket) do
    # Reset provider selection
    socket =
      socket
      |> assign(:selected_provider, nil)
      |> assign(:provider_models, [])

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_provider", %{"provider" => provider}, socket) do
    # Find models for this provider
    provider_models =
      case Enum.find(socket.assigns.models_grouped, fn {p, _} -> p == provider end) do
        {_, models} -> models
        nil -> []
      end

    socket =
      socket
      |> assign(:selected_provider, provider)
      |> assign(:provider_models, provider_models)

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_model", %{"_target" => ["model"], "model" => ""}, socket) do
    # Ignore when reset to placeholder
    {:noreply, socket}
  end

  @impl true
  def handle_event("select_model", %{"model" => model_id}, socket) when model_id != "" do
    # Find the model details
    selected_model = find_model(socket.assigns.models, model_id)

    # Update the form with new model
    current_params = socket.assigns.form.params || %{}
    new_params = Map.put(current_params, "model", model_id)

    changeset =
      (socket.assigns.endpoint || %Endpoint{})
      |> AI.change_endpoint(new_params)
      |> Map.put(:action, :validate)

    socket =
      socket
      |> assign(:form, to_form(changeset))
      |> assign(:selected_model, selected_model)

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_model", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("clear_model", _params, socket) do
    # Clear the model selection
    current_params = socket.assigns.form.params || %{}
    new_params = Map.put(current_params, "model", "")

    changeset =
      (socket.assigns.endpoint || %Endpoint{})
      |> AI.change_endpoint(new_params)
      |> Map.put(:action, :validate)

    socket =
      socket
      |> assign(:form, to_form(changeset))
      |> assign(:selected_model, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("set_manual_model", %{"model" => model_id}, socket) when model_id != "" do
    # Set model from manual input (when models list not loaded)
    current_params = socket.assigns.form.params || %{}
    new_params = Map.put(current_params, "model", model_id)

    changeset =
      (socket.assigns.endpoint || %Endpoint{})
      |> AI.change_endpoint(new_params)
      |> Map.put(:action, :validate)

    socket =
      socket
      |> assign(:form, to_form(changeset))
      |> assign(:selected_model, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("set_manual_model", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_reasoning", _params, socket) do
    # Toggle the reasoning_enabled value in form params
    current_value =
      socket.assigns.form.params["reasoning_enabled"] == "true" ||
        socket.assigns.form.params["reasoning_enabled"] == true ||
        (socket.assigns.endpoint && socket.assigns.endpoint.reasoning_enabled == true)

    new_value = if current_value, do: "false", else: "true"
    updated_params = Map.put(socket.assigns.form.params, "reasoning_enabled", new_value)

    form = %{socket.assigns.form | params: updated_params}
    {:noreply, assign(socket, :form, form)}
  end

  @impl true
  def handle_event("select_provider_connection", %{"action" => "deselect"}, socket) do
    # Clicking the currently-selected card unpicks it. Write nil into
    # the form params so save/2 persists the unpinning instead of
    # re-using the last-stamped value.
    updated_params = Map.put(socket.assigns.form.params, "integration_uuid", nil)
    form = %{socket.assigns.form | params: updated_params}

    socket =
      socket
      |> assign(:form, form)
      |> assign(:active_connection, nil)
      |> assign(:selected_uuids, [])
      |> assign(:integration_connected, false)
      |> assign(:models, [])
      |> assign(:models_grouped, [])
      |> stop_model_fetch_indicators()
      |> assign(:models_error, nil)

    {:noreply, socket}
  end

  def handle_event("select_provider_connection", %{"uuid" => uuid}, socket) do
    # Pin the endpoint to the chosen integration row by uuid.
    updated_params = Map.put(socket.assigns.form.params, "integration_uuid", uuid)
    form = %{socket.assigns.form | params: updated_params}

    connected = Integrations.connected?(uuid)

    socket =
      socket
      |> assign(:form, form)
      |> assign(:active_connection, uuid)
      |> assign(:selected_uuids, [uuid])
      |> assign(:integration_connected, connected)

    # Reload models with new connection
    if connected do
      send(self(), :fetch_models_from_integration)
      {:noreply, start_model_fetch_indicators(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("retry_model_fetch", _params, socket) do
    # Re-trigger `:fetch_models_from_integration` after a previous
    # fetch failed. Surfaced via the retry button on the model picker
    # error pane so operators don't have to re-pick the integration
    # to recover from a transient upstream failure (5xx, timeout,
    # rate-limit). The handler is a no-op if the active integration
    # isn't connected anymore — same gate as the initial fetch.
    if socket.assigns[:integration_connected] do
      send(self(), :fetch_models_from_integration)
      {:noreply, start_model_fetch_indicators(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save", %{"endpoint" => params}, socket) do
    # Merge provider_settings from nested params
    provider_settings = %{
      "http_referer" => get_in(params, ["provider_settings", "http_referer"]) || "",
      "x_title" => get_in(params, ["provider_settings", "x_title"]) || ""
    }

    params = Map.put(params, "provider_settings", provider_settings)

    # Stamp integration_uuid from the picker's current state — a uuid
    # when one is selected, nil when the operator unpicked (or never
    # picked one). Always writing means an explicit deselect actually
    # clears the column on save instead of silently retaining the
    # previously-stored value. The legacy `provider` column stays at
    # whatever it was (defaults to "openrouter") — not used for
    # resolution anymore, just kept until the column is dropped.
    params = Map.put(params, "integration_uuid", socket.assigns[:active_connection])

    # Parse numeric fields and string lists
    params =
      params
      |> parse_float("temperature")
      |> parse_integer("max_tokens")
      |> parse_float("top_p")
      |> parse_integer("top_k")
      |> parse_float("frequency_penalty")
      |> parse_float("presence_penalty")
      |> parse_float("repetition_penalty")
      |> parse_integer("seed")
      |> parse_integer("dimensions")
      |> parse_string_list("stop")

    save_endpoint(socket, params)
  end

  defp maybe_handle_provider_change(params, socket) do
    new_provider = params["provider"]
    current_provider = socket.assigns[:current_provider]

    provider_changed? =
      is_binary(new_provider) and is_binary(current_provider) and new_provider != current_provider

    if provider_changed? do
      params = Map.put(params, "base_url", nil)

      socket =
        socket
        |> assign(:active_connection, nil)
        |> assign(:selected_uuids, [])
        |> assign(:integration_connected, false)
        |> assign(:models, [])
        |> assign(:models_grouped, [])
        |> assign(:selected_model, nil)
        |> assign(:selected_provider, nil)
        |> assign(:provider_models, [])
        |> stop_model_fetch_indicators()
        |> assign(:models_error, nil)

      {params, socket}
    else
      {params, socket}
    end
  end

  defp reload_connections(socket) do
    connections = load_all_provider_connections()
    current_active = socket.assigns[:active_connection]
    endpoint_uuid = socket.assigns[:endpoint] && socket.assigns.endpoint.integration_uuid

    {active, orphaned} =
      cond do
        # Current selection still exists in the list — keep it.
        current_active && Enum.any?(connections, &(&1.uuid == current_active)) ->
          {current_active, nil}

        # Endpoint was originally pinned to a now-deleted integration.
        # Keep `active` nil so we don't silently switch the endpoint
        # to a different connection; surface the orphan to the picker.
        endpoint_uuid && not Enum.any?(connections, &(&1.uuid == endpoint_uuid)) ->
          {nil, endpoint_uuid}

        true ->
          {nil, nil}
      end

    selected_uuids =
      cond do
        active -> [active]
        orphaned -> [orphaned]
        true -> []
      end

    connected = active && Integrations.connected?(active)

    socket
    |> assign(:provider_connections, connections)
    |> assign(:active_connection, active)
    |> assign(:selected_uuids, selected_uuids)
    |> assign(:integration_connected, connected)
  end

  # Loads connections for every AI provider in one shot. The picker
  # filters client-side via its `provider` attr (matches `data["provider"]`),
  # so feeding it the union lets a `provider` field change in the form
  # immediately re-filter the cards without a server round-trip — and
  # without us having to track which provider the connections are for.
  defp load_all_provider_connections do
    Endpoint.valid_providers()
    |> Enum.flat_map(&Integrations.list_connections/1)
  end

  # Normalise a form field value (always a string from HTML) into the
  # shape the changeset expects. Blank strings become nil; invalid
  # numeric input is left untouched so Ecto can emit its own error.
  defp parse_field(params, key, parser) do
    case params[key] do
      nil -> params
      "" -> Map.put(params, key, nil)
      val when is_binary(val) -> Map.put(params, key, parser.(val, params[key]))
      _ -> params
    end
  end

  defp parse_float(params, key) do
    parse_field(params, key, fn val, original ->
      case Float.parse(val) do
        {num, _} -> num
        :error -> original
      end
    end)
  end

  defp parse_integer(params, key) do
    parse_field(params, key, fn val, original ->
      case Integer.parse(val) do
        {num, _} -> num
        :error -> original
      end
    end)
  end

  defp parse_string_list(params, key) do
    parse_field(params, key, fn val, _original ->
      list =
        val
        |> String.split(~r/[\r\n]+/)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      if list == [], do: nil, else: list
    end)
  end

  defp save_endpoint(socket, params) do
    opts = actor_opts(socket)

    result =
      if socket.assigns.endpoint do
        AI.update_endpoint(socket.assigns.endpoint, params, opts)
      else
        AI.create_endpoint(params, opts)
      end

    case result do
      {:ok, endpoint} ->
        action = if socket.assigns.endpoint, do: "updated", else: "created"
        message = save_success_message(endpoint, action)

        {:noreply,
         socket
         |> put_flash(:info, message)
         |> push_navigate(to: Routes.ai_path())}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  rescue
    e ->
      Logger.error(
        "Endpoint save failed: " <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      {:noreply, put_flash(socket, :error, gettext("Something went wrong. Please try again."))}
  end

  # Builds the post-save flash message, appending a soft warning when the
  # endpoint's `provider` points at an integration that is not currently
  # connected AND there is no legacy `api_key` fallback. Save still
  # succeeds — the user is free to connect the integration afterwards.
  defp save_success_message(endpoint, action) do
    base = gettext("Endpoint %{action} successfully", action: action)

    case integration_warning(endpoint) do
      nil -> base
      warning -> base <> ". " <> warning
    end
  end

  @doc false
  # Public for testability. Returns the soft-warning string for an
  # endpoint whose chosen integration isn't reachable AND has no legacy
  # `api_key` fallback. Returns nil when any branch of the resolution
  # ladder keeps the endpoint working at request time. Mirrors the
  # ladder in `OpenRouterClient.resolve_api_key/1` so the warning can't
  # disagree with what the next request would actually do.
  def integration_warning(endpoint) when is_map(endpoint) do
    integration_uuid = Map.get(endpoint, :integration_uuid)
    provider = Map.get(endpoint, :provider)
    api_key = Map.get(endpoint, :api_key)

    cond do
      # Endpoint pinned via integration_uuid — that specific row is
      # the source of truth, regardless of what the legacy `provider`
      # column still says.
      is_binary(integration_uuid) and integration_uuid != "" and
          Integrations.connected?(integration_uuid) ->
        nil

      # Legacy endpoint with a stored api_key — fallback path still works.
      is_binary(api_key) and api_key != "" ->
        nil

      # Pinned to an integration that isn't reachable — surface that.
      is_binary(integration_uuid) and integration_uuid != "" ->
        gettext(
          "The selected integration is not connected — requests will fail until you connect it in Settings → Integrations."
        )

      # No integration_uuid, but the legacy `provider` column may
      # carry a uuid (pre-V107) or a `provider:name` string. The
      # dual-input shim handles both shapes.
      is_binary(provider) and provider != "" ->
        if Integrations.connected?(provider) do
          nil
        else
          gettext(
            "The %{provider} integration is not connected — requests will fail until you connect it in Settings → Integrations.",
            provider: "\"#{provider}\""
          )
        end

      true ->
        gettext(
          "No integration configured for this endpoint. Set up the API key in Settings → Integrations."
        )
    end
  end

  # Captures the current admin/user's UUID so the Activity feed can
  # attribute the mutation to the right actor. Returns an empty list
  # when the scope isn't available (e.g. in isolated test sockets).
  defp actor_opts(socket) do
    role = if admin?(socket), do: "admin", else: "user"

    case socket.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} when is_binary(uuid) -> [actor_uuid: uuid, actor_role: role]
      _ -> [actor_role: role]
    end
  end

  defp admin?(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      nil -> false
      scope -> Scope.admin?(scope)
    end
  end

  # PubSub: reload connections when integrations change
  @impl true
  def handle_info({event, _, _}, socket)
      when event in [
             :integration_setup_saved,
             :integration_connected,
             :integration_connection_added
           ] do
    {:noreply, reload_connections(socket)}
  end

  def handle_info({event, _}, socket)
      when event in [:integration_disconnected, :integration_connection_removed] do
    {:noreply, reload_connections(socket)}
  end

  def handle_info({:integration_validated, _, _}, socket) do
    {:noreply, reload_connections(socket)}
  end

  @impl true
  def handle_info(:fetch_models_from_integration, socket) do
    # All three current providers (OpenRouter, Mistral, DeepSeek)
    # expose `<base_url>/models` with an OpenAI-compatible
    # `{"data": [{"id": ...}, ...]}` shape. The fetcher uses the
    # endpoint's `base_url` to hit the right host, and groups by
    # the endpoint's `provider` for IDs without a slash (so Mistral's
    # "mistral-large-latest" and DeepSeek's "deepseek-chat" land in
    # one group rather than each spawning a one-off group).
    #
    # Only fetch for the picker's actual selection. Falling back to
    # "any openrouter:default connection" silently misled operators
    # whose integration was named anything other than "default" (and
    # contradicted the picker's "reflect state, never auto-pick"
    # policy).
    active_key = socket.assigns[:active_connection]

    case active_key && Integrations.get_credentials(active_key) do
      {:ok, %{"api_key" => api_key}} when is_binary(api_key) and api_key != "" ->
        send(self(), {:fetch_models, api_key})
        {:noreply, socket}

      _ ->
        socket =
          socket
          |> stop_model_fetch_indicators()
          |> assign(:models_error, "No API key configured")

        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:fetch_models, api_key}, socket) do
    base_url = current_models_base_url(socket)
    fallback_provider = socket.assigns[:current_provider]

    fetch_opts = [
      model_type: :all,
      base_url: base_url,
      fallback_provider: fallback_provider
    ]

    case OpenRouterClient.fetch_models_grouped(api_key, fetch_opts) do
      {:ok, grouped} ->
        # Flatten for easy lookup
        models =
          grouped
          |> Enum.flat_map(fn {_provider, models} -> models end)

        # Set selected model if editing existing endpoint
        selected_model =
          case socket.assigns.endpoint do
            %{model: model_id} when is_binary(model_id) and model_id != "" ->
              find_model(models, model_id)

            _ ->
              nil
          end

        socket =
          socket
          |> stop_model_fetch_indicators()
          |> assign(:models, models)
          |> assign(:models_grouped, grouped)
          |> assign(:models_error, nil)
          |> assign(:selected_model, selected_model)

        {:noreply, socket}

      {:error, reason} ->
        # Log the failure with grep-able context (provider + reason) so
        # operators can correlate "model dropdown is empty" reports with
        # upstream API issues. Provider is the form-side selection at
        # the time of fetch.
        Logger.warning(fn ->
          "[PhoenixKitAI.Web.EndpointForm] model fetch failed: " <>
            "provider=#{inspect(socket.assigns[:current_provider])}, " <>
            "reason=#{inspect(reason)}"
        end)

        socket =
          socket
          |> stop_model_fetch_indicators()
          |> assign(:models_error, PhoenixKitAI.Errors.message(reason))

        {:noreply, socket}
    end
  end

  # The integration's `/models` fetch is wedged or slow; the picker
  # spinner has been spinning for 10s. Surface a "still loading" hint
  # so the operator knows it's not the UI that's stuck — they can
  # decide to wait or cancel out. The handler is idempotent: if the
  # actual fetch already completed, models_loading is false and we
  # leave models_loading_slow false too (no UI change).
  @impl true
  def handle_info(:model_fetch_slow, socket) do
    if socket.assigns[:models_loading] do
      {:noreply, assign(socket, :models_loading_slow, true)}
    else
      {:noreply, socket}
    end
  end

  # Catch-all for unmatched messages (PubSub from other modules, late
  # replies after navigation, etc.). Log at :debug per the workspace
  # sync precedent — never silently swallow a message we didn't expect.
  @impl true
  def handle_info(msg, socket) do
    Logger.debug(fn ->
      "[PhoenixKitAI.Web.EndpointForm] unhandled handle_info: #{inspect(msg)}"
    end)

    {:noreply, socket}
  end

  # Private helpers

  defp find_model(models, model_id) do
    Enum.find(models, fn m -> m.id == model_id end)
  end

  # Sets the loading indicator and schedules a 10s "still loading"
  # timer. The timer ref is stashed on the socket so the completion
  # handlers can cancel it. If the fetch completes before 10s, the
  # timer fires harmlessly into the no-op branch of the slow handler.
  # If 10s passes first, the spinner gains a "still loading" hint so
  # the operator knows it's not a wedged UI.
  defp start_model_fetch_indicators(socket) do
    cancel_model_fetch_slow_timer(socket)

    timer_ref = Process.send_after(self(), :model_fetch_slow, 10_000)

    socket
    |> assign(:models_loading, true)
    |> assign(:models_loading_slow, false)
    |> assign(:models_error, nil)
    |> assign(:model_fetch_slow_timer, timer_ref)
  end

  # Reset path — fetch completed (success or error). Cancels the
  # 10s timer if still pending and clears all loading-state assigns.
  defp stop_model_fetch_indicators(socket) do
    cancel_model_fetch_slow_timer(socket)

    socket
    |> assign(:models_loading, false)
    |> assign(:models_loading_slow, false)
    |> assign(:model_fetch_slow_timer, nil)
  end

  defp cancel_model_fetch_slow_timer(socket) do
    case socket.assigns[:model_fetch_slow_timer] do
      ref when is_reference(ref) -> Process.cancel_timer(ref)
      _ -> :ok
    end
  end

  # Resolves the base URL the model fetcher should hit. Prefers the
  # endpoint's saved `base_url` (in case the operator overrode it),
  # falls back to the schema default for the currently-selected
  # provider, then to OpenRouter's URL as a last resort. This is
  # what keeps Mistral / DeepSeek model fetches honest — the saved
  # endpoint may not exist yet on the new-endpoint flow, so we have
  # to derive from the form-side `current_provider` assign instead.
  defp current_models_base_url(socket) do
    endpoint_url = socket.assigns[:endpoint] && socket.assigns.endpoint.base_url

    cond do
      is_binary(endpoint_url) and endpoint_url != "" ->
        endpoint_url

      is_binary(socket.assigns[:current_provider]) ->
        Endpoint.default_base_url(socket.assigns.current_provider) ||
          OpenRouterClient.base_url()

      true ->
        OpenRouterClient.base_url()
    end
  end

  @doc """
  Parameter definitions with type, constraints, and UI metadata.
  Only parameters we support in the UI are defined here.
  """
  def parameter_definitions do
    %{
      # Basic parameters
      "temperature" => %{
        type: :float,
        label: "Temperature",
        min: 0,
        max: 2,
        step: 0.1,
        default: 0.7,
        field: :temperature,
        group: :basic,
        description: "Controls randomness in responses"
      },
      "max_tokens" => %{
        type: :integer,
        label: "Max Tokens",
        min: 1,
        field: :max_tokens,
        group: :basic,
        description: "Maximum tokens to generate"
      },
      "top_p" => %{
        type: :float,
        label: "Top P",
        min: 0,
        max: 1,
        step: 0.1,
        field: :top_p,
        group: :basic,
        description: "Nucleus sampling threshold"
      },
      "top_k" => %{
        type: :integer,
        label: "Top K",
        min: 1,
        field: :top_k,
        group: :basic,
        description: "Top-k sampling parameter"
      },
      # Advanced parameters
      "frequency_penalty" => %{
        type: :float,
        label: "Frequency Penalty",
        min: -2,
        max: 2,
        step: 0.1,
        field: :frequency_penalty,
        group: :advanced,
        description: "Penalize frequent tokens"
      },
      "presence_penalty" => %{
        type: :float,
        label: "Presence Penalty",
        min: -2,
        max: 2,
        step: 0.1,
        field: :presence_penalty,
        group: :advanced,
        description: "Penalize tokens already present"
      },
      "repetition_penalty" => %{
        type: :float,
        label: "Repetition Penalty",
        min: 0,
        max: 2,
        step: 0.1,
        field: :repetition_penalty,
        group: :advanced,
        description: "Penalize repeated sequences"
      },
      "seed" => %{
        type: :integer,
        label: "Seed",
        field: :seed,
        group: :advanced,
        placeholder: "Random",
        description: "For reproducible outputs"
      },
      "stop" => %{
        type: :string_list,
        label: "Stop Sequences",
        field: :stop,
        group: :advanced,
        placeholder: "One per line",
        description: "Sequences that stop generation"
      }
    }
  end

  @doc """
  Returns parameters supported by the model, filtered to ones we have UI for.
  Groups them by :basic and :advanced.
  """
  def get_supported_params(nil) do
    # No model selected - show all parameters
    definitions = parameter_definitions()
    group_parameters(Map.keys(definitions), definitions)
  end

  def get_supported_params(%AIModel{} = model) do
    definitions = parameter_definitions()
    supported_keys = Enum.filter(model.supported_parameters, &Map.has_key?(definitions, &1))
    group_parameters(supported_keys, definitions)
  end

  def get_supported_params(model) when is_map(model) do
    supported = model["supported_parameters"] || []
    definitions = parameter_definitions()
    supported_keys = Enum.filter(supported, &Map.has_key?(definitions, &1))
    group_parameters(supported_keys, definitions)
  end

  defp group_parameters(keys, definitions) do
    keys
    |> Enum.map(fn key -> {key, definitions[key]} end)
    |> Enum.group_by(fn {_key, def} -> def.group end)
    |> Map.new(fn {group, params} ->
      {group, Enum.sort_by(params, fn {key, _} -> key end)}
    end)
  end

  @doc """
  Gets the max tokens limit for the selected model.
  """
  def model_max_tokens(nil), do: nil

  def model_max_tokens(%AIModel{} = model) do
    model.max_completion_tokens || model.context_length
  end

  def model_max_tokens(model) when is_map(model) do
    model["max_completion_tokens"] || model["context_length"]
  end

  @doc """
  Formats a number with thousands separators.
  """
  def format_number(nil), do: "0"
  def format_number(num) when is_integer(num), do: Integer.to_string(num) |> add_commas()
  def format_number(num) when is_float(num), do: round(num) |> Integer.to_string() |> add_commas()
  def format_number(num) when is_binary(num), do: num

  defp add_commas(str) do
    str
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end
end
