defmodule EvoDashWeb.ProjectsLive.TaskSubmit do
  @moduledoc """
  The pure option-building core of the Projects page task launch.

  This module owns ONLY the transformation
  `{combined UI mode, form params, page assigns, objective}` → `start_task` opts.
  It performs no I/O, no store/registry/RPC call and no socket mutation: it
  neither receives nor returns a `%Phoenix.LiveView.Socket{}` — `assigns` is a
  plain assigns map (`socket.assigns`) and the caller keeps ownership of the
  launch, the flash and the post-launch form reset.

  ## Functions

    * `mode/1` — the dashboard combined-mode string → `{task_type, core_mode}`.
      The core's mode string is deliberately distinct from the UI's combined
      mode (`"custom_agent"` → the evolve-family `"custom"`), and an unknown UI
      string falls back to `{:evolve, "simple"}` exactly as before.
    * `build_opts/6` — assembles the launch payload in the historical order:
      message text, `:build_system`, `:node_path`, `:starting_commit`,
      `:foreign_repos`, `:archive`, `:resume_from`, the staged-attachment
      re-check and the base64 `:attachments` opt.

  The LAST step of `build_opts/6` is
  `EvoDashWeb.ProjectsLive.LaunchOptions.apply/2`, whose result is returned
  unchanged: the launch policy (validated model selection, custom agent, quality
  level, `persistent_state`) stays owned by that module so normal submissions
  and GitHub fixes can never diverge.

  ## Tolerance contract

  Shapes the previous inline code tolerated stay tolerated: an absent/non-binary
  `"node_path"`/`"starting_commit"`/`"resume_from"`/`"build_system"` param is
  simply skipped, and nil `:foreign_repos`/`:staged_attachments` assigns are
  treated as empty. Nothing new is made lenient: an unknown `"build_system"`
  string still raises `ArgumentError` through `String.to_existing_atom/1`, and a
  non-binary objective still raises through `String.trim/1`, exactly as today.

  The attachment cap is re-checked here belt-and-braces (the staging flow
  already enforces it): an over-cap payload answers
  `{:error, :attachments_over_cap}` so the caller can keep the staged state and
  let the user trim it.
  """

  alias EvoDashWeb.ProjectsLive.LaunchOptions

  # Mirrors `EvoGit.Attachments`' per-task attachment cap and per-file RAW byte
  # budget (the authoritative validation), the same two caps
  # `EvoDash.AttachedFile` keeps in sync for the staging flow.
  @max_attachments 4
  @max_attachment_bytes 15 * 1024 * 1024

  @typedoc "Task type handed to `EvoGit.TaskRegistry.start_task/2`."
  @type task_type :: :genesis | :evolve

  @doc """
  Maps the dashboard combined-mode string to `{task_type, core_mode_string}`.

  Unknown strings fall back to `{:evolve, "simple"}`, matching the page's
  historical `case` catch-all.
  """
  @spec mode(term()) :: {task_type(), String.t()}
  def mode("genesis_new"), do: {:genesis, "new"}
  def mode("genesis_existing"), do: {:genesis, "existing"}
  def mode("evolve_simple"), do: {:evolve, "simple"}
  # Custom Agent mode is evolve-family: an :evolve task with the selected
  # custom agent as the root agent (the core contract's mode string is
  # "custom" — distinct from the UI's combined-mode string).
  def mode("custom_agent"), do: {:evolve, "custom"}
  def mode(_combined_mode), do: {:evolve, "simple"}

  @doc """
  Builds the `start_task` opts for one submission.

  `task_type`/`mode`/`path` are already derived by `mode/1` and the page;
  `params` is the submitted form params map and `assigns` is the page's assigns
  map (read keys: `:foreign_repos`, `:staged_attachments`, plus everything
  `LaunchOptions.apply/2` consumes).

  Returns `{:ok, opts}` or `{:error, reason}` — either the attachment cap
  re-check (`:attachments_over_cap`) or `LaunchOptions.apply/2`'s own refusal.
  """
  @spec build_opts(String.t(), task_type(), String.t(), term(), map(), map()) ::
          {:ok, keyword()} | {:error, term()}
  def build_opts(prompt, task_type, mode, path, params, assigns) do
    with :ok <- check_attachments(assigns[:staged_attachments]) do
      [path: path, mode: mode]
      |> put_message(prompt, task_type)
      |> put_build_system(params["build_system"], task_type)
      |> put_node_path(params["node_path"], task_type)
      |> put_starting_commit(params["starting_commit"], task_type)
      |> put_foreign_repos(assigns[:foreign_repos])
      |> put_archive(params["archive"])
      |> put_resume_from(params["resume_from"], task_type)
      |> put_attachments(assigns[:staged_attachments])
      |> LaunchOptions.apply(assigns)
    end
  end

  defp put_message(opts, prompt, :genesis),
    do: Keyword.put(opts, :prompt, String.trim(prompt))

  defp put_message(opts, prompt, :evolve),
    do: Keyword.put(opts, :objective, String.trim(prompt))

  # An unknown build system must stay a visible ArgumentError (the atom is part
  # of the evolution runtime's contract), never a silently dropped option.
  defp put_build_system(opts, build_system, :genesis) when is_binary(build_system) do
    if String.trim(build_system) != "" do
      Keyword.put(opts, :build_system, String.to_existing_atom(build_system))
    else
      opts
    end
  end

  defp put_build_system(opts, _build_system, _task_type), do: opts

  defp put_node_path(opts, node_path, :evolve) when is_binary(node_path) do
    if String.trim(node_path) != "" do
      Keyword.put(opts, :node_path, String.trim(node_path))
    else
      opts
    end
  end

  defp put_node_path(opts, _node_path, _task_type), do: opts

  defp put_starting_commit(opts, starting_commit, :evolve) when is_binary(starting_commit) do
    if String.trim(starting_commit) != "" do
      Keyword.put(opts, :starting_commit, String.trim(starting_commit))
    else
      opts
    end
  end

  defp put_starting_commit(opts, _starting_commit, _task_type), do: opts

  defp put_foreign_repos(opts, foreign_repos) do
    case foreign_repos || [] do
      [] -> opts
      repos -> Keyword.put(opts, :foreign_repos, repos)
    end
  end

  defp put_archive(opts, archive_param) do
    if archive_param == "true", do: Keyword.put(opts, :archive, true), else: opts
  end

  defp put_resume_from(opts, resume_from, :evolve) when is_binary(resume_from) do
    if String.trim(resume_from) != "" do
      Keyword.put(opts, :resume_from, String.trim(resume_from))
    else
      opts
    end
  end

  defp put_resume_from(opts, _resume_from, _task_type), do: opts

  # Staged binary attachments (image/audio) → the `:attachments` task opt. Raw
  # bytes are staged in-memory only; the task-opts layer must carry BASE64 (the
  # core Store.Codec Jason-encodes opts — raw non-UTF-8 binaries would abort the
  # encode and silently drop the key). Leave opts untouched when nothing is
  # staged (byte-identical old behavior).
  defp put_attachments(opts, staged) do
    case staged || [] do
      [] ->
        opts

      entries ->
        attachments =
          Enum.map(entries, fn entry ->
            # Entries are built by the staging flow with all four keys;
            # Map.get defaults keep this defensive against odd shapes.
            %{
              "type" => Map.get(entry, "type", "image"),
              "name" => Map.get(entry, "name", ""),
              "media_type" => Map.get(entry, "media_type", "application/octet-stream"),
              "data" => Base.encode64(Map.get(entry, "data", ""))
            }
          end)

        Keyword.put(opts, :attachments, attachments)
    end
  end

  # Belt-and-braces cap re-check (staging already enforces the caps, so this
  # should be unreachable): refuse to start — WITHOUT touching the staged state
  # — so the user can trim attachments and retry.
  defp check_attachments(staged) do
    staged = staged || []

    over_cap? =
      length(staged) > @max_attachments or
        Enum.any?(staged, fn entry ->
          is_map(entry) and is_binary(entry["data"]) and
            byte_size(entry["data"]) > @max_attachment_bytes
        end)

    if over_cap?, do: {:error, :attachments_over_cap}, else: :ok
  end
end
