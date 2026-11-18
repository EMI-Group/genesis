defmodule EvoGit.AgentState.RedispatchTest do
  # async: true — this module is a PURE projection: no app-env mutation, no
  # ETS table, no global process, no disk and no clock read.
  use ExUnit.Case, async: true

  alias EvoGit.AgentSpec
  alias EvoGit.AgentState.Redispatch
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.ForeignRepo
  alias EvoGit.Core.PhyloGraphNode

  # The exact key list the blob must contain — nothing more, nothing less.
  @keys ~w(
    agent_type delegation_level tools max_turns custom_agent_id model_spec
    node_path repo_id objective task_number task_local_id foreign_repos
    quality_level archive repo_less parent_id depth spawn_turn spawn_index
  )

  defmodule StubAgent do
    use EvoGit.Agent

    def agent_type, do: :read_write
    def delegation_level, do: :low
    def system_prompt, do: "redispatch test"
  end

  defp spec(opts \\ []) do
    context_node = %ContextNode{path: "./src/auth", repo: "/tmp/primary-repo"}
    phylo_node = PhyloGraphNode.new("/tmp/primary-repo", "base-sha")

    AgentSpec.new(
      context_node,
      phylo_node,
      StubAgent,
      "Implement the auth fix.",
      Keyword.merge([repo_id: "primary"], opts)
    )
  end

  defp foreign_repo do
    ForeignRepo.new("original", "/tmp/original-repo",
      description: "The original monorepo",
      writable: true,
      base_sha: "abc123"
    )
  end

  defp facts do
    [
      tools: ["read", :write, :rg],
      max_turns: 42,
      custom_agent_id: "crew-lead",
      model_spec: %{
        "provider_profile_id" => "acct-1",
        "model" => "gpt-5.1",
        "reasoning_effort" => "high"
      },
      node_path: "./src/auth",
      task_number: 12,
      task_local_id: 3,
      quality_level: "fast",
      archive: true,
      repo_less: false,
      parent_id: 7,
      depth: 2,
      spawn_turn: 5,
      spawn_index: 1
    ]
  end

  describe "build/2 → to_spec_opts/1 round-trip" do
    test "preserves every rebuildable fact" do
      blob = Redispatch.build(spec(foreign_repos: [foreign_repo()]), facts())
      opts = Redispatch.to_spec_opts(blob)

      assert Keyword.keys(opts) |> Enum.sort() == Enum.sort(Enum.map(@keys, &String.to_atom/1))

      assert opts[:agent_type] == :read_write
      assert opts[:delegation_level] == :low
      assert opts[:tools] == ["read", "write", "rg"]
      assert opts[:max_turns] == 42
      assert opts[:custom_agent_id] == "crew-lead"

      assert opts[:model_spec] == %{
               "provider_profile_id" => "acct-1",
               "model" => "gpt-5.1",
               "reasoning_effort" => "high"
             }

      assert opts[:node_path] == "./src/auth"
      assert opts[:repo_id] == "primary"
      assert opts[:objective] == "Implement the auth fix."
      assert opts[:task_number] == 12
      assert opts[:task_local_id] == 3

      assert [%ForeignRepo{} = repo] = opts[:foreign_repos]
      assert repo.id == "original"
      assert repo.root == "/tmp/original-repo"
      assert repo.writable == true
      assert repo.base_sha == "abc123"

      assert opts[:quality_level] == "fast"
      assert opts[:archive] == true
      assert opts[:repo_less] == false
      assert opts[:parent_id] == 7
      assert opts[:depth] == 2
      assert opts[:spawn_turn] == 5
      assert opts[:spawn_index] == 1
    end

    test "the role facts come from the spec, and spec.opts projections are the fallback" do
      # No facts at all: the spec still yields the role, the objective, the
      # repo id and the opts projections — and a nil spec.opts[:max_turns]
      # stays absent instead of being invented.
      opts =
        spec(
          archive: true,
          custom_agent_id: "from-spec",
          node_path: "./src",
          quality_level: "deep"
        )
        |> Redispatch.build([])
        |> Redispatch.to_spec_opts()

      assert opts[:agent_type] == :read_write
      assert opts[:delegation_level] == :low
      assert opts[:objective] == "Implement the auth fix."
      assert opts[:repo_id] == "primary"
      assert opts[:archive] == true
      assert opts[:custom_agent_id] == "from-spec"
      assert opts[:node_path] == "./src"
      assert opts[:quality_level] == "deep"
      refute Keyword.has_key?(opts, :max_turns)
      refute Keyword.has_key?(opts, :tools)
      refute Keyword.has_key?(opts, :parent_id)

      # An explicit spec.opts[:max_turns] wins over a facts value.
      spec_turns =
        spec(max_turns: 9) |> Redispatch.build(max_turns: 42) |> Redispatch.to_spec_opts()

      assert spec_turns[:max_turns] == 9
    end

    test "foreign repos are plain maps in the blob, structs after the inverse" do
      blob = Redispatch.build(spec(foreign_repos: [foreign_repo()]), [])

      assert blob["foreign_repos"] == [
               %{
                 "id" => "original",
                 "path" => "/tmp/original-repo",
                 "writable" => true,
                 "base_sha" => "abc123"
               }
             ]

      # A structurally unusable entry is dropped rather than raising.
      assert Redispatch.build(spec(foreign_repos: [%{"id" => "broken"}]), [])["foreign_repos"] ==
               []
    end
  end

  describe "JSON cleanliness" do
    test "the blob survives Jason.encode!/1 + Jason.decode/1 byte-identically" do
      blob = Redispatch.build(spec(foreign_repos: [foreign_repo()]), facts())

      decoded = blob |> Jason.encode!() |> Jason.decode!()

      # Values are already JSON-native (atoms stored as strings), so the
      # decoded map IS the build map — and the inverse yields the same opts.
      assert decoded == blob
      assert Redispatch.to_spec_opts(decoded) == Redispatch.to_spec_opts(blob)
    end

    test "an atom-keyed map is accepted exactly like a string-keyed one" do
      atom_keyed = %{
        agent_type: :read,
        delegation_level: :high,
        tools: [:read, "rg"],
        max_turns: 3,
        custom_agent_id: "x",
        model_spec: %{"model" => "m"},
        node_path: "./",
        repo_id: "primary",
        objective: "o",
        task_number: 1,
        task_local_id: 2,
        foreign_repos: [
          %{id: "original", path: "/tmp/original-repo", writable: false, base_sha: nil}
        ],
        quality_level: "fast",
        archive: false,
        repo_less: true,
        parent_id: 4,
        depth: 1,
        spawn_turn: 6,
        spawn_index: 0
      }

      string_keyed = %{
        "agent_type" => "read",
        "delegation_level" => "high",
        "tools" => ["read", "rg"],
        "max_turns" => 3,
        "custom_agent_id" => "x",
        "model_spec" => %{"model" => "m"},
        "node_path" => "./",
        "repo_id" => "primary",
        "objective" => "o",
        "task_number" => 1,
        "task_local_id" => 2,
        "foreign_repos" => [
          %{"id" => "original", "path" => "/tmp/original-repo", "writable" => false}
        ],
        "quality_level" => "fast",
        "archive" => false,
        "repo_less" => true,
        "parent_id" => 4,
        "depth" => 1,
        "spawn_turn" => 6,
        "spawn_index" => 0
      }

      assert Redispatch.to_spec_opts(atom_keyed) == Redispatch.to_spec_opts(string_keyed)
      assert Redispatch.to_spec_opts(atom_keyed)[:agent_type] == :read
      assert Redispatch.to_spec_opts(atom_keyed)[:archive] == false
      assert Redispatch.to_spec_opts(atom_keyed)[:repo_less] == true
    end
  end

  describe "the blob carries no runtime state" do
    test "unknown facts and non-JSON values never reach the blob" do
      junk_facts = [
        pid: self(),
        fun: fn -> :ok end,
        llm_generation_params: %{temperature: 0.2, top_k: 40},
        provider_options: [auth_mode: :oauth, oauth_file: "/tmp/auth.json"],
        api_key: "sk-secret",
        context_node: %ContextNode{path: "./src", repo: "/tmp/repo"},
        phylo_node: PhyloGraphNode.new("/tmp/repo", "sha"),
        # A KNOWN key whose value is not rebuildable data degrades to nil.
        task_number: self()
      ]

      blob = Redispatch.build(spec(), junk_facts)

      assert Map.keys(blob) |> Enum.sort() == Enum.sort(@keys)
      refute Map.has_key?(blob, "pid")
      refute Map.has_key?(blob, "fun")
      refute Map.has_key?(blob, "llm_generation_params")
      refute Map.has_key?(blob, "provider_options")
      refute Map.has_key?(blob, "api_key")
      refute Map.has_key?(blob, "context_node")
      refute Map.has_key?(blob, "phylo_node")
      assert blob["task_number"] == nil

      refute deep_match?(blob, &is_pid/1)
      refute deep_match?(blob, &is_function/1)
      refute deep_match?(blob, &is_reference/1)

      assert {:ok, _json} = Jason.encode(blob)
    end
  end

  describe "totality" do
    test "to_spec_opts/1 answers [] for anything that is not a map" do
      assert Redispatch.to_spec_opts(nil) == []
      assert Redispatch.to_spec_opts("blob") == []
      assert Redispatch.to_spec_opts([{"agent_type", "read"}]) == []
      assert Redispatch.to_spec_opts(%{}) == []
    end

    test "a partial or malformed blob degrades value-by-value" do
      opts =
        Redispatch.to_spec_opts(%{
          "agent_type" => 123,
          "tools" => "read",
          "max_turns" => 0,
          "custom_agent_id" => nil,
          "model_spec" => "not-a-map",
          "foreign_repos" => "nope",
          "archive" => "yes"
        })

      assert opts == []
    end

    test "a fact list that is not a keyword list contributes no facts" do
      blob = Redispatch.build(spec(), [:not_a_pair])

      assert blob["task_number"] == nil
      assert blob["agent_type"] == "read_write"
    end
  end

  # --- helpers --------------------------------------------------------------

  defp deep_match?(term, predicate) do
    cond do
      is_map(term) -> Enum.any?(Map.values(term), &deep_match?(&1, predicate))
      is_list(term) -> Enum.any?(term, &deep_match?(&1, predicate))
      true -> predicate.(term)
    end
  end
end
