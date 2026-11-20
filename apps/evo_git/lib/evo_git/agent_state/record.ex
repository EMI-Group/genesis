defmodule EvoGit.AgentState.Record do
  @moduledoc """
  The persisted shape of ONE agent run's durable state.

  A record is the scalar `fields` map plus the rebuilt conversation
  `messages`, joined from the `agent_states` row and its ordered
  `agent_state_chunks` rows.

  ## Field decoding

  `fields` is ATOM-keyed with exactly the keys the checkpointing session
  supplies (see `EvoGit.AgentState`):

    * text columns decode to strings;
    * boolean columns decode to `true | false` (`nil` when never written);
    * `:agent_module` decodes back to the module atom when it is already
      loaded, else to the stored string;
    * JSON columns (`:model_spec`, `:usage`, `:pending_inputs`, …) decode to
      Jason's native shape — STRING-keyed maps, never atoms.

  Message payloads are `:erlang.term_to_binary(messages, compressed: 6)`
  blobs; decoding is total and any corrupt blob yields `:error` (the caller
  maps that to `{:error, :corrupt_state}`).
  """

  @enforce_keys [:task_id, :agent_id]
  defstruct [
    :task_id,
    :agent_id,
    :fields,
    :messages,
    :message_count,
    :chunk_count,
    :format_version,
    :inserted_at,
    :updated_at,
    :completed_at
  ]

  @type t :: %__MODULE__{
          task_id: String.t(),
          agent_id: integer(),
          fields: %{atom() => term()},
          messages: [ReqLLM.Message.t()],
          message_count: non_neg_integer() | nil,
          chunk_count: non_neg_integer() | nil,
          format_version: non_neg_integer() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil
        }

  # The caller-supplied scalar fields and their columns. This list is the ONE
  # source of column names; SQL is always built from it, never from caller
  # input.
  @field_specs [
    {:agent_module, "agent_module", :module},
    {:depth, "depth", :integer},
    {:parent_id, "parent_id", :integer},
    {:node_path, "node_path", :text},
    {:repo_id, "repo_id", :text},
    {:repo_less, "repo_less", :boolean},
    {:repo_root, "repo_root", :text},
    {:custom_agent_id, "custom_agent_id", :text},
    {:mode, "mode", :text},
    {:archive, "archive", :boolean},
    {:objective, "objective", :text},
    {:model_spec, "model_spec", :json},
    {:provider_profile_id, "provider_profile_id", :text},
    {:model_id, "model_id", :text},
    {:model_id_locked, "model_id_locked", :boolean},
    {:prompt_cache_key, "prompt_cache_key", :text},
    {:llm_model, "llm_model", :text},
    {:llm_context_window, "llm_context_window", :integer},
    {:turn, "turn", :integer},
    {:usage, "usage", :json},
    {:total_tokens, "total_tokens", :integer},
    {:compression_count, "compression_count", :integer},
    {:current_commit, "current_commit", :text},
    {:phase, "phase", :text},
    {:pending_inputs, "pending_inputs", :json},
    {:pending_tool_batch, "pending_tool_batch", :json},
    {:status, "status", :text},
    # Written ONLY by `EvoGit.AgentState.Store.put_pause_commit/4` (the sha of
    # the worktree checkpoint an agent made when it paused); readable through
    # `record.fields[:pause_commit]` like the other scalar fields.
    {:pause_commit, "pause_commit", :text},
    # v2 run facts (migration `000004_add_run_facts`): where in the parent's
    # tool batch this child was spawned, its own git branch/base/anchor, the
    # re-dispatch payload a restart rebuilds an `%AgentSpec{}` from, and the
    # finished run's JSON result.
    {:spawn_turn, "spawn_turn", :integer},
    {:spawn_index, "spawn_index", :integer},
    {:branch, "branch", :text},
    {:base_commit, "base_commit", :text},
    {:anchor_ref, "anchor_ref", :text},
    {:redispatch, "redispatch", :json},
    {:result, "result", :json}
  ]

  # The MUTABLE per-turn scalars: the only fields a RUNNING agent rewrites on
  # every checkpoint. Everything else is excluded on purpose —
  #   * identity and run facts (`depth`, `parent_id`, `branch`, `base_commit`,
  #     `objective`, `redispatch`, …) never change after a run starts, so
  #     rewriting them each turn would re-encode the same JSON for nothing;
  #   * `pause_commit` has its own single-column write
  #     (`EvoGit.AgentState.Store.put_pause_commit/4`) and `result` its own
  #     (`mark_done/5`).
  # The list is a SUBSET SELECTOR over `@field_specs`, so column names still
  # come from the ONE source list above.
  @volatile_field_keys [
    :turn,
    :usage,
    :total_tokens,
    :compression_count,
    :current_commit,
    :phase,
    :pending_inputs,
    :pending_tool_batch,
    :status
  ]

  @volatile_field_specs Enum.filter(@field_specs, fn {key, _column, _type} ->
                          key in @volatile_field_keys
                        end)

  @doc "The `{field_key, column, type}` specs, in deterministic column order."
  @spec field_specs() :: [{atom(), String.t(), atom()}]
  def field_specs, do: @field_specs

  @doc "The scalar field columns, in deterministic order."
  @spec field_columns() :: [String.t()]
  def field_columns, do: Enum.map(@field_specs, fn {_key, column, _type} -> column end)

  # The two JSON columns NO roster consumer reads: `usage` is per-run
  # accounting (read through `load/3`) and `pending_inputs` is the drained-input
  # queue (read by the live session). `redispatch` and `objective` deliberately
  # STAY in the roster projection — `EvoGit.Agent.Resume.RosterBatch.build_spec/2`
  # rebuilds a subagent spec from both.
  @roster_omitted_columns ["pending_inputs", "usage"]

  @doc """
  The LEAN column projection the roster reads select: `all_columns/0` minus the
  two heavy JSON columns (`pending_inputs` and `usage`) that no roster consumer
  reads.

  `redispatch` and `objective` are NOT omitted (a resume rebuilds a spec from
  them), and `decode_fields/1` tolerates an absent column: a roster record's
  `fields` map still carries EVERY atom key, with `nil` for the two omitted
  values.
  """
  @spec roster_columns() :: [String.t()]
  def roster_columns do
    Enum.reject(all_columns(), fn column -> column in @roster_omitted_columns end)
  end

  @doc """
  The MUTABLE per-turn `{field_key, column, type}` specs (`volatile_columns/0`'s
  source), in `field_specs/0` order.
  """
  @spec volatile_field_specs() :: [{atom(), String.t(), atom()}]
  def volatile_field_specs, do: @volatile_field_specs

  @doc """
  The mutable per-turn columns: `turn`, `usage`, `total_tokens`,
  `compression_count`, `current_commit`, `phase`, `pending_inputs`,
  `pending_tool_batch` and `status`.

  Deliberately EXCLUDES `pause_commit` (its own single-column write) and
  `result` (written by `mark_done/5`) plus every identity/run fact, because
  none of those change after a run starts.
  """
  @spec volatile_columns() :: [String.t()]
  def volatile_columns do
    Enum.map(@volatile_field_specs, fn {_key, column, _type} -> column end)
  end

  @doc """
  Every column of an `agent_states` row, in the order `load/3` selects them.
  """
  @spec all_columns() :: [String.t()]
  def all_columns do
    ["task_id", "agent_id"] ++
      field_columns() ++
      [
        "format_version",
        "message_count",
        "chunk_count",
        "created_at",
        "updated_at",
        "completed_at"
      ]
  end

  @doc """
  Encodes a caller `fields` map into `[{column, value}]`, keeping ONLY the keys
  the caller actually supplied (an upsert must never clobber an earlier value
  with a default). Unknown keys are ignored; atom and string keys are both
  accepted.
  """
  @spec encode_fields(map()) :: [{String.t(), term()}]
  def encode_fields(fields) when is_map(fields) do
    Enum.flat_map(@field_specs, fn {key, column, type} ->
      case fetch_field(fields, key) do
        {:ok, value} -> [{column, encode_value(type, value)}]
        :error -> []
      end
    end)
  end

  def encode_fields(_fields), do: []

  @doc """
  Encodes a caller `fields` map into `[{column, value}]` for EVERY volatile
  column (`volatile_columns/0`), with REPLACE semantics: a key the caller
  omitted encodes as SQL `NULL` instead of being skipped.

  The caller must therefore supply the FULL volatile snapshot on every write —
  unlike `encode_fields/1` there is no "leave the stored value alone" arm. A
  non-map encodes the whole projection as `NULL`.

  Encoding is type-driven ONLY: a nullable column (`usage`, `pending_inputs`,
  `phase`, `current_commit`, `pending_tool_batch`) clears to `NULL`, while the
  `NOT NULL` columns (`turn`, `total_tokens`, `compression_count`, `status`)
  cannot hold one — `EvoGit.AgentState.Store.update_volatile/4` binds those
  through `COALESCE` to their own table default.
  """
  @spec encode_volatile_fields(map()) :: [{String.t(), term()}]
  def encode_volatile_fields(fields) when is_map(fields) do
    Enum.map(@volatile_field_specs, fn {key, column, type} ->
      case fetch_field(fields, key) do
        {:ok, value} -> {column, encode_value(type, value)}
        :error -> {column, nil}
      end
    end)
  end

  def encode_volatile_fields(_fields) do
    Enum.map(@volatile_field_specs, fn {_key, column, _type} -> {column, nil} end)
  end

  @doc "Decodes a column-keyed row map into the atom-keyed `fields` map."
  @spec decode_fields(map()) :: %{atom() => term()}
  def decode_fields(row) when is_map(row) do
    Map.new(@field_specs, fn {key, column, type} ->
      {key, decode_value(type, Map.get(row, column))}
    end)
  end

  @doc """
  The persisted `status` of the run — `"running"` or `"done"` — or `nil`.

  Total for ANY input: a non-record, a record without the field or a
  non-binary stored value answers `nil` instead of raising.
  """
  @spec status(t() | term()) :: String.t() | nil
  def status(%__MODULE__{fields: fields}) when is_map(fields) do
    case Map.get(fields, :status) do
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  def status(_record), do: nil

  @doc """
  The persisted `result` of a FINISHED run — a STRING-keyed JSON map — or
  `nil` for a running row (and for a value that is not a JSON object).

  Total for ANY input.
  """
  @spec result(t() | term()) :: map() | nil
  def result(%__MODULE__{fields: fields}) when is_map(fields) do
    case Map.get(fields, :result) do
      value when is_map(value) -> value
      _other -> nil
    end
  end

  def result(_record), do: nil

  @doc "Encodes a message list into the chunk payload blob."
  @spec encode_messages([ReqLLM.Message.t()]) :: binary()
  def encode_messages(messages) when is_list(messages) do
    :erlang.term_to_binary(messages, compressed: 6)
  end

  @doc """
  Decodes one chunk payload back into a message list.

  Total: a truncated/garbage payload (or a payload that is not a list of
  `%ReqLLM.Message{}`) returns `:error`, never raises.
  """
  @spec decode_messages(term()) :: {:ok, [ReqLLM.Message.t()]} | :error
  def decode_messages(payload) when is_binary(payload) do
    # Justified rescue: this is the ONE centralized boundary decoding a
    # previously-stored blob. `:erlang.binary_to_term/1` raises
    # `ArgumentError` on corruption and has no non-raising variant, so the
    # rescue is the only way to answer `:error` instead of crashing the reader.
    try do
      case :erlang.binary_to_term(payload) do
        messages when is_list(messages) ->
          if Enum.all?(messages, fn message -> is_struct(message, ReqLLM.Message) end) do
            {:ok, messages}
          else
            :error
          end

        _other ->
          :error
      end
    rescue
      _error -> :error
    end
  end

  def decode_messages(_payload), do: :error

  @doc "Parses a stored ISO8601 timestamp; total (`nil` on absence/garbage)."
  @spec parse_datetime(term()) :: DateTime.t() | nil
  def parse_datetime(nil), do: nil
  def parse_datetime(%DateTime{} = datetime), do: datetime

  def parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  def parse_datetime(_value), do: nil

  @doc """
  The current UTC time as an ISO8601 string at second precision.

  String ordering then implements retention ordering.
  """
  @spec now_iso8601() :: String.t()
  def now_iso8601 do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  ## Encoding

  defp fetch_field(fields, key) do
    case Map.fetch(fields, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(fields, Atom.to_string(key))
    end
  end

  defp encode_value(_type, nil), do: nil

  defp encode_value(:boolean, false), do: 0
  defp encode_value(:boolean, true), do: 1
  defp encode_value(:boolean, 0), do: 0
  defp encode_value(:boolean, _value), do: 1

  defp encode_value(:integer, value), do: value

  defp encode_value(:module, value) when is_atom(value), do: Atom.to_string(value)
  defp encode_value(:module, value) when is_binary(value), do: value
  defp encode_value(:module, value), do: inspect(value)

  defp encode_value(:text, value) when is_binary(value), do: value
  defp encode_value(:text, value) when is_atom(value), do: Atom.to_string(value)
  defp encode_value(:text, value), do: to_string_or_inspect(value)

  defp encode_value(:json, value) do
    case Jason.encode(value) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> inspect(value)
    end
  end

  defp to_string_or_inspect(value) do
    if String.Chars.impl_for(value), do: to_string(value), else: inspect(value)
  end

  ## Decoding

  defp decode_value(_type, nil), do: nil

  defp decode_value(:boolean, value) when value in [0, false], do: false
  defp decode_value(:boolean, _value), do: true

  defp decode_value(:integer, value), do: value
  defp decode_value(:text, value), do: value

  defp decode_value(:module, value) when is_binary(value) do
    # Justified rescue: `String.to_existing_atom/1` is the only safe
    # string→atom conversion and it raises for an atom that is no longer
    # loaded; decoding must stay total, so a miss falls back to the string.
    try do
      String.to_existing_atom(value)
    rescue
      ArgumentError -> value
    end
  end

  defp decode_value(:module, value), do: value

  defp decode_value(:json, value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> value
    end
  end

  defp decode_value(:json, value), do: value
end
