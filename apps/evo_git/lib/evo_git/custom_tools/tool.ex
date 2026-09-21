defmodule EvoGit.CustomTools.Tool do
  @moduledoc """
  Behaviour for **user-defined custom tools**.

  A custom tool is a plain Elixir module authored by the user, dropped into
  `<config_dir>/tools/` as a `.ex`, `.exs` or `.beam` file, and loaded
  dynamically by `EvoGit.CustomTools.Loader`. Each module describes itself with
  `schema/0` (a `ReqLLM.Tool`) and implements its own `execute/2`.

  Custom tools are the tool-level sibling of the `agents.toml`
  `[model_selection] script`: both evaluate user-authored Elixir inside the
  running BEAM. See the security notes below.

  ## Minimal example

      defmodule MyProject.WeatherTool do
        @behaviour EvoGit.CustomTools.Tool

        @impl true
        def schema do
          ReqLLM.tool(
            name: "get_weather",
            description: "Returns the weather for a city.",
            parameter_schema: %{
              "type" => "object",
              "properties" => %{
                "city" => %{"type" => "string", "description" => "City name"}
              },
              "required" => ["city"]
            },
            callback: fn _ -> {:ok, nil} end
          )
        end

        @impl true
        def execute(%{"city" => city}, ctx) do
          case HTTPoison.get("https://example.test/weather?city=" <> city) do
            {:ok, %{body: body}} -> body
            {:error, reason} -> "Error: weather lookup failed: " <> inspect(reason)
          end
        end

        @impl true
        def read_only?, do: true
      end

  ## Tool name

  The tool name exposed to the LLM is **`schema().name`** — nothing else. The
  module name is irrelevant to the agent; only the schema's `name` field
  identifies the tool. The name must be a non-empty binary.

  ## `execute/2` contract

  `execute(args, ctx)` receives:

    * `args` — the decoded tool-call arguments map (whatever the LLM produced,
      validated only by the schema's `parameter_schema` as far as the provider
      enforces it). Keys are whatever the schema declares.
    * `ctx` — a plain map with the caller's context:

          %{
            repo_path: String.t(),          # the agent's working directory
            repo_root: String.t() | nil,    # the git repository root, if any
            node_path: String.t() | nil     # the agent's assigned context-tree node
          }

  It **MUST return a `String`** — either human/LLM-readable success text, or a
  failure described as an `"Error: ..."` string. Returning a non-string value is
  a contract violation (`EvoGit.CustomTools.execute/3` converts such a value
  into an error string).

  `execute/2` **should never crash the agent loop**. Prefer catching your own
  recoverable errors and returning an `"Error: ..."` string. As a
  defense-in-depth measure the dispatch layer wraps tool calls so that a raise,
  throw or exit is mapped to an error string instead of killing the agent — but
  a tool must NOT rely on that boundary: an unexpected crash still aborts the
  in-progress turn and is far harder to debug than a returned error string.

  ## `read_only?/0` (optional)

  `read_only?/0` classifies the tool for the dispatch write gate. It **defaults
  to `false`**, which classifies the tool as a **WRITE tool** — a deliberately
  conservative/safe default: a tool that forgets to declare itself read-only is
  blocked for repo-less agents and for agents operating inside a read-only
  foreign repository, exactly like the built-in write tools. Only an explicit
  `true` marks a tool as read-only.

  The classification only matters for the write gate; both read-only and write
  custom tools are advertised to the LLM through the same schema list.

  ## Security

  Files in `<config_dir>/tools/` are **user-authored code**, equivalent to the
  `agents.toml` `[model_selection] script` (which already evaluates user Elixir
  in-process):

    * Custom tools are compiled and loaded into the running BEAM with **full
      privileges**. There is NO load-time sandbox.
    * Tool **execution is not sandboxed by default** — a custom tool runs in the
      normal agent process. A tool that needs isolation (filesystem restrictions,
      resource limits, ...) must apply `EvoGit.Sandbox` itself.
    * Only load custom tools you trust.
  """

  @typedoc "Context map passed as the second argument to `execute/2`."
  @type ctx :: %{
          repo_path: String.t(),
          repo_root: String.t() | nil,
          node_path: String.t() | nil
        }

  @doc """
  Returns the `ReqLLM.Tool` describing this custom tool.

  The tool's `name` field identifies it to the LLM and must be a non-empty
  binary. The schema's `callback` is never used by the custom-tool dispatch
  path — `execute/2` below is the real implementation.
  """
  @callback schema() :: ReqLLM.Tool.t()

  @doc """
  Executes the tool with the LLM-provided `args` and the caller's `ctx`.

  MUST return a `String` (success text or an `"Error: ..."` string). Should not
  crash the agent loop.
  """
  @callback execute(args :: map(), ctx :: ctx()) :: String.t()

  @doc """
  Whether this tool is read-only.

  Optional — defaults to `false` (a WRITE tool, the conservative default). Only
  an explicit `true` marks the tool as read-only for the dispatch write gate.
  """
  @callback read_only?() :: boolean()

  @optional_callbacks read_only?: 0
end
