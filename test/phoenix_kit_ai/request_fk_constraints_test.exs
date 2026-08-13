defmodule PhoenixKitAI.RequestFkConstraintsTest do
  @moduledoc """
  Regression guard for FK violations escaping `Request.changeset/2` as raw
  `Ecto.ConstraintError` (a 500) instead of changeset errors.

  Core names these constraints `fk_ai_requests_*` in its v135 chain, not the
  `phoenix_kit_ai_requests_<field>_fkey` that `foreign_key_constraint/2` derives
  by default, so a declaration without an explicit `:name` never matches.

  `prompt_uuid` is the awkward one: v135 adds its FK TWICE under two different
  names, each block guarded only by its own name, so a freshly migrated database
  carries both while an older one carries only
  `phoenix_kit_ai_requests_prompt_uuid_fkey` (measured on the max-dev box). The
  changeset therefore declares both names, and this test asserts the behaviour
  that matters — a changeset error, not a raise — against whichever name the
  database under test actually has.
  """
  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKitAI.Request

  defp endpoint_fixture do
    {:ok, ep} =
      PhoenixKitAI.create_endpoint(%{
        name: "EP-#{System.unique_integer([:positive])}",
        provider: "openrouter",
        model: "a/b",
        api_key: "sk-test-key"
      })

    ep
  end

  defp base_attrs do
    %{status: "success", model: "a/b", input_tokens: 1, output_tokens: 1, total_tokens: 2}
  end

  test "a non-existent prompt_uuid returns a changeset error, not a raise" do
    attrs = Map.put(base_attrs(), :prompt_uuid, Ecto.UUID.generate())

    assert {:error, %Ecto.Changeset{} = changeset} = PhoenixKitAI.create_request(attrs)
    assert Keyword.has_key?(changeset.errors, :prompt_uuid)
  end

  test "a non-existent user_uuid returns a changeset error, not a raise" do
    attrs = Map.put(base_attrs(), :user_uuid, Ecto.UUID.generate())

    assert {:error, %Ecto.Changeset{} = changeset} = PhoenixKitAI.create_request(attrs)
    assert Keyword.has_key?(changeset.errors, :user_uuid)
  end

  test "a non-existent endpoint_uuid returns a changeset error, not a raise" do
    attrs = Map.put(base_attrs(), :endpoint_uuid, Ecto.UUID.generate())

    assert {:error, %Ecto.Changeset{} = changeset} = PhoenixKitAI.create_request(attrs)
    assert Keyword.has_key?(changeset.errors, :endpoint_uuid)
  end

  test "a valid endpoint reference still inserts" do
    ep = endpoint_fixture()
    attrs = Map.put(base_attrs(), :endpoint_uuid, ep.uuid)

    assert {:ok, request} = PhoenixKitAI.create_request(attrs)
    assert request.endpoint_uuid == ep.uuid
  end

  test "every belongs_to on the schema declares a foreign key constraint" do
    declared =
      %Request{}
      |> Request.changeset(base_attrs())
      |> Map.fetch!(:constraints)
      |> Enum.filter(&(&1.type == :foreign_key))
      |> MapSet.new(& &1.field)

    associated =
      Request.__schema__(:associations)
      |> Enum.map(&Request.__schema__(:association, &1))
      |> Enum.filter(&match?(%Ecto.Association.BelongsTo{}, &1))
      |> MapSet.new(& &1.owner_key)

    missing = MapSet.difference(associated, declared)

    assert MapSet.equal?(missing, MapSet.new()),
           """
           These belongs_to keys have no foreign_key_constraint: #{inspect(MapSet.to_list(missing))}

           Without one, a violation raises Ecto.ConstraintError instead of
           returning a changeset error. Declare it with the name core's migration
           actually creates (`fk_ai_requests_<field>`), not the Ecto default.
           """
  end
end
