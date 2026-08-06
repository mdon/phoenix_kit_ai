defmodule PhoenixKitAI.Components.AITranslate.FormBinding do
  @moduledoc """
  The small storage-specific contract a form LiveView supplies to the
  shared AI-translate glue (`PhoenixKitAI.Components.AITranslate.FormGlue`).

  Everything about the modal/progress/stall state machine, the dispatch, and
  the PubSub event handling is generic and lives in the glue. The only things
  that differ per consumer are *where/how translations are stored in the live
  changeset* and *who the actor is* — those three callbacks.

  Implementations are tiny modules (see `PhoenixKitCatalogue.AITranslateBinding`
  / `PhoenixKitProjects.AITranslateBinding`). The module is passed once to
  `FormGlue.assign_ai_translation/4` and stashed in assigns.
  """

  @doc """
  The enabled non-primary language codes that ALREADY have at least one
  non-blank translatable field, read from the live form's assigns (so it
  reflects unsaved + just-translated state). The glue subtracts these from the
  enabled set to get the "missing" list.
  """
  @callback existing_translation_langs(resource_type :: String.t(), assigns :: map()) ::
              [String.t()]

  @doc """
  Merge a completed translation's `fields` (plain engine field names →
  translated values) into `changeset` for `lang`, returning the updated
  changeset. PURE changeset→changeset — the glue re-assigns it via the LV's
  own assign helper, so this must not touch the socket.
  """
  @callback apply_translation(
              resource_type :: String.t(),
              changeset :: Ecto.Changeset.t(),
              lang :: String.t(),
              fields :: map()
            ) :: Ecto.Changeset.t()

  @doc "The acting user's UUID (or nil) for the translation audit trail."
  @callback actor_uuid(socket :: Phoenix.LiveView.Socket.t()) :: Ecto.UUID.t() | nil

  @doc """
  OPTIONAL — the primary-language source text for VALUE MODE, read from the
  live form's assigns: `%{"field" => "text"}` (engine field names, non-blank
  strings; blank/missing fields are simply not translated).

  Exporting this callback is what turns AI translation ON for UNSAVED
  resources (`:new` forms): with no record for the Oban worker to load or
  write, the glue translates these values directly and folds the results
  into the live changeset via `apply_translation/4` — they persist with the
  eventual create. Bindings without it keep the old behavior (AI disabled
  until the record exists).
  """
  @callback source_fields(resource_type :: String.t(), assigns :: map()) :: %{
              optional(String.t()) => String.t()
            }

  @optional_callbacks source_fields: 2
end
