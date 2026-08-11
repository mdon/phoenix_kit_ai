defmodule PhoenixKitAI.I18nTest do
  @moduledoc """
  Smoke test for the per-module i18n wiring.

  Confirms that:
    * Every admin tab registered by `PhoenixKitAI.admin_tabs/0` carries
      `gettext_backend: PhoenixKitAI.Gettext`.
    * Locale switching on the module's own backend produces translated
      labels for at least one well-known msgid (regression guard for the
      `priv/gettext/<locale>/LC_MESSAGES/default.po` shipping with the
      package).
    * `Tab.localized_label/1` falls back to the raw msgid for an unknown
      locale.

  These msgids are added by hand to the `.po` files (not by
  `mix gettext.extract`) — `Tab.localized_label/1` calls
  `Gettext.dgettext(backend, domain, label)` with `label` as a runtime
  variable, which the extractor can never see. See
  `priv/gettext/ru/LC_MESSAGES/default.po` for the manual entries and
  `guides/per-module-i18n.md` in `phoenix_kit` core for why.
  """

  use ExUnit.Case, async: true

  # Excluded by `test/test_helper.exs` when running against a `phoenix_kit`
  # release that pre-dates the `gettext_backend` API (PR BeamLabEU/phoenix_kit#522).
  # Once the consumer's `phoenix_kit` dep resolves to a release that ships
  # `Tab.localized_label/1`, the helper detects it and these tests run
  # automatically — no follow-up edit needed.
  @moduletag :requires_phoenix_kit_i18n_api

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKitAI.Gettext, as: AIGettext

  describe "admin_tabs/0 wiring" do
    test "every tab carries the module's own gettext backend" do
      for tab <- PhoenixKitAI.admin_tabs() do
        assert tab.gettext_backend == AIGettext,
               "Tab #{inspect(tab.id)} is missing or wrong gettext_backend " <>
                 "(got #{inspect(tab.gettext_backend)})"
      end
    end
  end

  describe "Tab.localized_label/1 against the module's catalogue" do
    test "ru locale resolves the parent 'AI' tab to 'AI' (intentionally untranslated)" do
      parent = Enum.find(PhoenixKitAI.admin_tabs(), &(&1.id == :admin_ai))

      Gettext.with_locale(AIGettext, "ru", fn ->
        assert Tab.localized_label(parent) == "AI"
      end)
    end

    test "ru locale resolves the 'Endpoints' tab to 'Конечные точки'" do
      tab = Enum.find(PhoenixKitAI.admin_tabs(), &(&1.id == :admin_ai_endpoints))

      Gettext.with_locale(AIGettext, "ru", fn ->
        assert Tab.localized_label(tab) == "Конечные точки"
      end)
    end

    test "et locale resolves the 'Endpoints' tab to 'Lõpp-punktid'" do
      tab = Enum.find(PhoenixKitAI.admin_tabs(), &(&1.id == :admin_ai_endpoints))

      Gettext.with_locale(AIGettext, "et", fn ->
        assert Tab.localized_label(tab) == "Lõpp-punktid"
      end)
    end

    test "ru locale resolves the 'Usage' tab to 'Использование'" do
      tab = Enum.find(PhoenixKitAI.admin_tabs(), &(&1.id == :admin_ai_usage))

      Gettext.with_locale(AIGettext, "ru", fn ->
        assert Tab.localized_label(tab) == "Использование"
      end)
    end

    test "unknown locale falls back to the raw msgid" do
      tab = Enum.find(PhoenixKitAI.admin_tabs(), &(&1.id == :admin_ai_endpoints))

      Gettext.with_locale(AIGettext, "zz", fn ->
        assert Tab.localized_label(tab) == tab.label
      end)
    end
  end

  describe "permission_metadata/0 wiring" do
    test "carries the module's own gettext backend for the permissions matrix" do
      meta = PhoenixKitAI.permission_metadata()

      assert meta.gettext_backend == AIGettext
      assert meta.gettext_domain == "default"
    end
  end
end
