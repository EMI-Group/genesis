# Regression guard for RETIRED model ids on the dashboard's model surfaces.
#
# The Settings page offers whatever `EvoGit.Config.LLMCatalog` ships: the Quick
# Setup panel renders one button per catalog model, tagged
# `phx-value-model_string="<provider_atom>:<model id>"`. A retired id that
# survives in the catalog (or in a fixture fed back into the page) silently
# offers users a model that no longer exists, so this file pins BOTH halves:
#
#   1. the CATALOG (the single source of the offered ids), and
#   2. the RENDERED Settings page for every catalog provider — the place the
#      ids actually reach the DOM.
#
# ASYNC: nothing here touches BEAM-global state. The config directory comes from
# the per-process `:config_dir_fun` seam (`EvoDash.Test.ConfigDir.isolate!/1`,
# installed by `test_helper.exs`), and the one shared ETS table touched
# (`EvoDash.ActiveTasks`) is cleared for the LOCAL context only.
defmodule EvoDashWeb.SettingsLive.ModelIdsTest do
  use EvoDashWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  # Models this project no longer ships. Extend this list when a model is
  # retired — a find/replace across the suite cannot stop the catalog from
  # re-adding one, which is why the guard lives here.
  # `claude-fable-5-1` is deliberately ABSENT: it is retired as a PREFIX spelling
  # but the catalog still ships the current `claude-fable-5-1` model, so only the
  # bare `claude-fable-5` shape is retired (see the matcher below).
  @retired_ids ~w(
    claude-opus-4-7
    claude-opus-4-8
    claude-sonnet-4-6
    claude-fable-5
    gpt-5.4
    gpt-5.5
    glm-5
    gemini-3.1-pro-preview
    kimi-k2.7
    qwen-3.6-plus
    qwen-3.7-max
    qwen-3.8-max
  )

  # Matching is bounded by every character a model id can CONTINUE with, so a
  # longer current id is never mistaken for a retired prefix:
  #   * `glm-5`          does NOT match `glm-5.3` / `glm-5.3-flashx` (`.` and `-`)
  #   * `claude-fable-5` does NOT match `claude-fable-5-1`            (`-`)
  #   * `kimi-k2.7`      does NOT match `kimi-k2.7-code`              (`-`)
  # A plain `String.contains?/2` would break every one of those cases, hence the
  # token-boundary regex.
  defp retired_id?(value, retired) do
    Regex.match?(~r/(?<![0-9a-z.\-])#{Regex.escape(retired)}(?![0-9a-z.\-])/i, value)
  end

  # Every retired id occurring in `value` (a single string or a whole HTML page),
  # e.g. `retired_matches("openai:gpt-5.5") == ["gpt-5.5"]`.
  defp retired_matches(value) when is_binary(value) do
    Enum.filter(@retired_ids, &retired_id?(value, &1))
  end

  setup do
    # Per-process config dir: an EMPTY temp dir guarantees no config.toml
    # exists, so the page renders catalog/schema defaults deterministically
    # regardless of the developer's real `~/.config/genesis`.
    dir = EvoDash.Test.ConfigDir.isolate!("evogit_settings_model_ids_test")
    on_exit(fn -> File.rm_rf!(dir) end)

    # Process-less public ETS table shared by the whole run — clear ONLY the
    # local `{nil, node()}` context (a whole-table reset would delete a
    # concurrent async module's snapshot).
    EvoDash.ActiveTasks.invalidate(nil, node())

    :ok
  end

  describe "retired-id matcher" do
    test "matches a bare id and a provider-prefixed model string" do
      assert retired_matches("claude-sonnet-4-6") == ["claude-sonnet-4-6"]
      assert retired_matches("anthropic:claude-sonnet-4-6") == ["claude-sonnet-4-6"]
      assert retired_matches(~s(phx-value-model_string="openai:gpt-5.5")) == ["gpt-5.5"]
      assert retired_matches("qwen-3.7-max") == ["qwen-3.7-max"]
      assert retired_matches("anthropic:claude-fable-5") == ["claude-fable-5"]
    end

    test "does NOT match a longer CURRENT id that starts with a retired prefix" do
      # These ids are shipped today; a naive `String.contains?/2` matcher would
      # flag them and make the catalog assertion below permanently red.
      assert retired_matches("glm-5.1") == []
      assert retired_matches("glm-5.2") == []
      assert retired_matches("zai:glm-5.3") == []
      assert retired_matches("glm-5.3-flashx") == []
      assert retired_matches("anthropic:claude-fable-5-1") == []
      assert retired_matches("kimi-k2.7-code") == []
      assert retired_matches("qwen3.8-max") == []
      assert retired_matches("claude-sonnet-5-5") == []
      assert retired_matches("glm-50") == []
    end
  end

  describe "LLMCatalog" do
    test "offers no retired model id" do
      catalog_ids =
        for provider <- EvoGit.Config.LLMCatalog.providers(),
            model <- provider.models,
            do: model.id

      assert catalog_ids != [],
             "the catalog must expose model ids for this guard to be meaningful"

      assert offenders(catalog_ids) == []
    end

    test "no provider / variant identifier is a retired model id" do
      # Belt and braces: the dashboard renders provider and variant identifiers
      # too (`phx-value-provider_id` / `phx-value-variant_id`), and a variant's
      # `credential_key` inherits the vendor/model naming a bad catalog edit
      # would introduce.
      identifiers =
        for provider <- EvoGit.Config.LLMCatalog.providers(),
            identifier <- binaries(provider_identifiers(provider)),
            do: identifier

      assert offenders(identifiers) == []
    end
  end

  describe "Settings page" do
    test "renders no retired model id", %{conn: conn} do
      {:ok, view, html} = mount_settings(conn)

      # The LLM category is the default mount, so the Quick Setup panel and its
      # provider list are on the page.
      assert html =~ "Quick Setup"
      assert retired_matches(html) == []
      assert retired_matches(render(view)) == []
    end

    test "every catalog provider's model shortcuts render only current ids", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn)

      for provider <- EvoGit.Config.LLMCatalog.providers() do
        html =
          render_hook(view, "select_llm_provider", %{
            "provider_id" => Atom.to_string(provider.id)
          })

        assert retired_matches(html) == [],
               "selecting provider #{inspect(provider.id)} rendered a retired model id"

        check_model_shortcuts(view, provider, html)
      end
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Assertion helpers
  # ───────────────────────────────────────────────────────────────────────────

  defp offenders(values) do
    for value <- values,
        matches = retired_matches(value),
        matches != [],
        do: {value, matches}
  end

  defp provider_identifiers(provider) do
    [
      Atom.to_string(provider.id),
      provider[:credential_key],
      provider[:oauth_source] && Atom.to_string(provider[:oauth_source])
    ] ++ variant_identifiers(provider[:variants])
  end

  defp variant_identifiers(nil), do: []

  defp variant_identifiers(variants) when is_list(variants) do
    Enum.flat_map(variants, fn variant ->
      [
        Atom.to_string(variant.id),
        Atom.to_string(variant.provider_atom),
        variant[:credential_key]
      ]
    end)
  end

  # Absent optional identifiers (`oauth_source`, a variant's `credential_key`)
  # are `nil` and simply not checked.
  defp binaries(values), do: Enum.filter(values, &is_binary/1)

  # Providers with variants hide their model shortcuts until a variant is
  # picked, so each variant gets its own render.
  defp check_model_shortcuts(view, provider, provider_html) do
    case provider[:variants] do
      variants when is_list(variants) and variants != [] ->
        for variant <- variants do
          html =
            render_hook(view, "select_llm_variant", %{
              "variant_id" => Atom.to_string(variant.id)
            })

          assert retired_matches(html) == [],
                 "variant #{inspect(variant.id)} of #{inspect(provider.id)} rendered a retired id"

          assert_current_model(html, variant.provider_atom, provider)
        end

      _ ->
        assert_current_model(
          provider_html,
          EvoGit.Config.LLMCatalog.resolve_provider_atom(provider.id, nil),
          provider
        )
    end
  end

  # Non-vacuity: when a provider HAS catalog models and shows shortcuts, at
  # least one current `provider:model` string must be in the markup — proving the
  # assertions above inspected real model buttons rather than an empty panel.
  defp assert_current_model(html, provider_atom, provider) do
    if provider[:custom_model] != true and provider.models != [] do
      expected = Enum.map(provider.models, &"#{provider_atom}:#{&1.id}")

      assert Enum.any?(expected, &(html =~ &1)),
             "provider #{inspect(provider.id)} rendered no model shortcut button"
    else
      :ok
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Mount helper — deterministic settle of the page's ASYNC loads
  # ───────────────────────────────────────────────────────────────────────────
  #
  # Every Settings mount kicks off an async load on `EvoDash.TaskSupervisor`
  # (`SettingsLive.NodeData`), whose apply REPLACES `:file_config` /
  # `:llm_providers`. Waiting for THIS mount's tasks to exit before driving
  # events keeps a late apply from landing mid-assertion. Same funnel as
  # `settings_live_test.exs`, duplicated because that one lives in another test
  # file's helper module and test files do not share load order.
  defp mount_settings(conn) do
    {:ok, view, html} = live(conn, "/settings")

    view.pid
    |> mount_async_task_pids()
    |> Enum.each(&await_task_exit/1)

    {:ok, view, html}
  end

  defp await_task_exit(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    after
      5_000 -> :ok
    end
  end

  defp mount_async_task_pids(view_pid) do
    EvoDash.TaskSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {_, pid, _, _} when is_pid(pid) ->
        if view_pid in task_callers(pid), do: [pid], else: []

      _ ->
        []
    end)
  end

  defp task_callers(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> Keyword.get(dict, :"$callers", [])
      _ -> []
    end
  end
end
