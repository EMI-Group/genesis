defmodule EvoDashWeb.SettingsLive.SearchEvents do
  @moduledoc """
  Search and reset event handlers extracted from SettingsLive.

  These handlers are isolated into their own module to keep SettingsLive
  focused on its core responsibility (category save, model profiles,
  credentials, remote connections, etc.).

  ## Handlers

    * `handle_search/2` — updates the search_text assign from a search form.
    * `handle_noop/2` — no-op handler that prevents page reload when pressing
      Enter in a form without a submit action.
    * `handle_reset_key/2` — resets a single configuration key to its schema
      default, persists the change, and reloads config.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  use Gettext, backend: EvoDashWeb.Gettext

  alias EvoDashWeb.SettingsLive.ConfigIO

  @doc """
  Handles the search event by updating the `:search_text` socket assign.

  Called from `SettingsLive.handle_event("search", params, socket)`.
  """
  def handle_search(socket, %{"value" => text}) do
    {:noreply, assign(socket, :search_text, text)}
  end

  @doc """
  No-op handler for form submissions that should not trigger any action.

  Prevents page reload when pressing Enter in forms (e.g. the search/filter
  form on the tasks page) that use `phx-submit="noop"`.

  Called from `SettingsLive.handle_event("noop", params, socket)`.
  """
  def handle_noop(socket, _params) do
    {:noreply, socket}
  end

  @doc """
  Resets a single configuration key to its schema-defined default value.

  Parses the key path, validates it against the known schema, resets the key
  in the file_config to its default, and persists the change through
  `EvoDashWeb.SettingsLive.persist_file_config/3` — the single config
  persistence entry point (LOCAL saves are synchronous but exit-safe, REMOTE
  saves run in a supervised task with the `config_saving` indicator and a node
  stale guard).

  Called from `SettingsLive.handle_event("reset_key", params, socket)`.
  """
  def handle_reset_key(socket, %{"key_path" => path_str}) do
    key_path = ConfigIO.parse_key_path(path_str, socket.assigns.schemas_by_category)
    schema = ConfigIO.find_schema(key_path, socket.assigns.schemas_by_category)

    # An unknown or stale key_path / schema means untrusted client input did not
    # resolve to a known setting — surface a friendly flash instead of crashing
    # on put_in with a nil path or a nil schema.default.
    if is_nil(key_path) or is_nil(schema) do
      {:noreply, put_flash(socket, :error, gettext("Invalid key path."))}
    else
      config = put_in(socket.assigns.file_config, key_path, schema.default)

      EvoDashWeb.SettingsLive.persist_file_config(
        config,
        socket,
        gettext("Reset %{key} to default.", key: path_str)
      )
    end
  end
end
