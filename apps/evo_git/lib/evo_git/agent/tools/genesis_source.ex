defmodule EvoGit.Agent.Tools.GenesisSource do
  @moduledoc "Optional, bounded Genesis source reference access for the built-in assistant."

  alias EvoGit.Agent.Tools.ElixirEval.Authorization
  alias EvoGit.Agent.Tools.Failure
  alias EvoGit.SelfReflectiveSource, as: Source

  @max_context_bytes 16_384

  def schema do
    ReqLLM.tool(
      name: "genesis_source",
      description:
        "Optional read-only Genesis source reference. status reports availability and versions; " <>
          "context reads the bounded root CONTEXT.md and gives its absolute reference path. " <>
          "prepare downloads missing reference source only after real user approval. " <>
          "Use only when source implementation details are needed; ordinary chat needs no source.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "action" => %{"type" => "string", "enum" => ["status", "context", "prepare"]},
          "purpose" => %{
            "type" => "string",
            "description" => "Why source is needed (prepare only)."
          }
        },
        "required" => ["action"],
        "additionalProperties" => false
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  def execute(args, _repo_path, _node_path, _opts \\ []) do
    with {:ok, auth} <- Authorization.authorize(),
         :ok <- validate(args) do
      perform(args["action"], args, auth)
    else
      {:error, reason} -> Failure.error(to_string(reason))
    end
  end

  # This snapshot describes the reference that would actually be read, including overrides;
  # Source.status/0's version/commit fields describe only its managed clone.
  def reference_status do
    path = Source.reference_path()

    available =
      is_binary(path) and File.dir?(path) and File.regular?(Path.join(path, "CONTEXT.md"))

    version = if available, do: read_version(path)
    runtime = Application.spec(:evo_git, :vsn) |> to_string()

    %{
      available: available,
      reference_path: if(available, do: path),
      target_path: Source.source_dir(),
      source_version: version,
      runtime_version: runtime,
      version_matches: if(is_binary(version), do: version == runtime, else: nil),
      reference_only: true
    }
  end

  defp perform("status", _, _), do: encode(reference_status())

  defp perform("context", _, _) do
    case reference_status() do
      %{available: true, reference_path: path} = status ->
        case File.open(Path.join(path, "CONTEXT.md"), [:read, :binary]) do
          {:ok, io} ->
            content =
              try do
                IO.binread(io, @max_context_bytes + 1)
              after
                File.close(io)
              end

            case content do
              text when is_binary(text) ->
                clipped = byte_size(text) > @max_context_bytes

                text =
                  text
                  |> binary_part(0, min(byte_size(text), @max_context_bytes))
                  |> String.replace_invalid()

                encode(
                  Map.merge(status, %{
                    context: text,
                    truncated: clipped,
                    note:
                      "Read-only reference; version_matches=false means this is not the running implementation."
                  })
                )

              _ ->
                Failure.error("Unable to read reference CONTEXT.md.")
            end

          {:error, reason} ->
            Failure.error("Unable to read reference CONTEXT.md: #{reason}.")
        end

      status ->
        encode(
          Map.put(
            status,
            :error,
            "Source unavailable. Request prepare only when source is needed."
          )
        )
    end
  end

  defp perform("prepare", args, auth) do
    if reference_status().available do
      encode(reference_status())
    else
      # Bind approval to the exact URL/path/purpose, and recheck them before downloading.
      parameters = %{
        "action" => "prepare",
        "purpose" => args["purpose"],
        "url" => Source.clone_url(),
        "path" => Source.source_dir()
      }

      conversation =
        case EvoGit.AgentScheduler.Store.get_sched_meta(auth.agent_id) do
          {:ok, meta} -> Keyword.get(meta.spec.opts, :assistant_conversation_id)
          _ -> nil
        end

      context = %{
        target_node: node(),
        agent_id: auth.agent_id,
        task_id: auth.task_id,
        conversation_id: conversation,
        project_path: parameters["path"],
        summary: "准备 Genesis 只读参考源码：" <> args["purpose"]
      }

      case EvoGit.CommandApproval.request_action("genesis_source", parameters, context) do
        :approved ->
          with :ok <- Authorization.revalidate(auth),
               true <-
                 Source.source_dir() == parameters["path"] and
                   Source.clone_url() == parameters["url"] do
            # Another caller may have completed the same preparation while approval waited.
            if reference_status().available do
              encode(reference_status())
            else
              case Source.clone_at(parameters["path"], parameters["url"]) do
                {:ok, _} ->
                  encode(reference_status())

                {:error, reason} ->
                  Failure.error(
                    "Source preparation failed: #{inspect(reason)}. Ordinary chat remains available."
                  )
              end
            end
          else
            _ ->
              Failure.error(
                "Source preparation authorization or target changed; request approval again."
              )
          end

        :denied ->
          Failure.error("Source preparation denied; no download was started.")

        :timeout ->
          Failure.error("Source preparation approval timed out; no download was started.")
      end
    end
  end

  defp validate(%{"action" => action} = args) when action in ["status", "context", "prepare"] do
    purpose = Map.get(args, "purpose")

    cond do
      Enum.any?(Map.keys(args), &(&1 not in ["action", "purpose"])) ->
        {:error, "Unknown source parameter."}

      action == "prepare" and
          not (is_binary(purpose) and String.valid?(purpose) and byte_size(purpose) <= 2000 and
                   String.trim(purpose) != "") ->
        {:error, "Source preparation requires a nonblank purpose (at most 2000 bytes)."}

      true ->
        :ok
    end
  end

  defp validate(_), do: {:error, "Source action must be status, context or prepare."}

  defp read_version(path) do
    case File.read(Path.join(path, "VERSION")) do
      {:ok, text} -> String.trim(text)
      _ -> nil
    end
  end

  defp encode(value), do: Jason.encode!(value)
end
