defmodule EvoGit.Agent.Tools.ElixirEval.ValidationTest do
  @moduledoc """
  Async-safe validation of capability arguments using only test-owned paths.
  Model lookup, self-targeting actions and authorization belong to broker tests;
  these cases never consult the global scheduler or submit runtime mutations.
  """
  use ExUnit.Case, async: true
  alias EvoGit.Agent.Tools.ElixirEval.Validation

  @moduletag :tmp_dir

  describe "start_options/2 types, modes and normalization" do
    test "accepts the four literal type strings and supplies only their documented defaults",
         %{tmp_dir: path} do
      assert {:ok, :genesis, genesis} =
               Validation.start_options("genesis", %{"path" => path, "prompt" => "Build it"})

      assert Map.new(genesis) == %{
               path: Path.expand(path),
               mode: "new",
               prompt: "Build it",
               objective: "Build it"
             }

      assert {:ok, :evolve, evolve} =
               Validation.start_options("evolve", %{path: path, objective: "Fix it"})

      assert Map.new(evolve) == %{path: Path.expand(path), mode: "simple", objective: "Fix it"}

      assert Validation.start_options("reflect", %{objective: "Explain it"}) ==
               {:ok, :reflect, [mode: "reflect", objective: "Explain it"]}

      assert {:ok, :extract_skills, extraction} =
               Validation.start_options("extract_skills", %{path: path})

      assert Map.new(extraction) == %{path: Path.expand(path)}
    end

    test "rejects unknown types, atom types, non-map options and non-string enums",
         %{tmp_dir: path} do
      for type <- ["custom", "Genesis", "genesis ", "", :genesis, nil, 1, %{}] do
        assert {:error, _} = Validation.start_options(type, %{path: path, objective: "Build"})
      end

      for options <- [nil, [], [objective: "Explain"], "objective=Explain", 1] do
        assert {:error, _} = Validation.start_options("reflect", options)
      end

      for mode <- [:reflect, "simple", "custom", "merge", "resume", "REFLECT", nil, 1] do
        assert {:error, _} =
                 Validation.start_options("reflect", %{objective: "Explain", mode: mode})
      end
    end

    test "genesis new/existing and evolve simple are the only repository modes",
         %{tmp_dir: path} do
      for mode <- ["new", "existing"] do
        assert {:ok, :genesis, opts} =
                 Validation.start_options("genesis", %{path: path, objective: "Build", mode: mode})

        assert opts[:mode] == mode
      end

      assert {:ok, :evolve, opts} =
               Validation.start_options("evolve", %{path: path, objective: "Fix", mode: "simple"})

      assert opts[:mode] == "simple"

      for type <- ["genesis", "evolve"],
          mode <- ["custom", "merge", "resume", :simple, "reflect"] do
        assert {:error, _} =
                 Validation.start_options(type, %{path: path, objective: "Do it", mode: mode})
      end

      assert {:error, _} =
               Validation.start_options("evolve", %{path: path, objective: "Fix", mode: "new"})

      assert {:error, _} =
               Validation.start_options("extract_skills", %{path: path, mode: "simple"})
    end

    test "accepts mixed literal key spellings but refuses duplicate interpretations",
         %{tmp_dir: path} do
      assert {:ok, :genesis, opts} =
               Validation.start_options("genesis", %{
                 "objective" => "Build",
                 path: path,
                 mode: "new"
               })

      assert opts[:objective] == "Build"

      for {atom, string} <- [
            {:objective, "objective"},
            {:mode, "mode"},
            {:path, "path"},
            {:prompt, "prompt"},
            {:model_id, "model_id"}
          ] do
        options = %{atom => "one", string => "two"}

        assert Validation.start_options("genesis", options) ==
                 {:error, "Unsupported or duplicate option."}
      end
    end

    test "rejects dangerous extra options even when their values look harmless" do
      for key <- [
            :agent,
            :foreign_repos,
            :resume_from,
            :merge_from,
            :merge_target,
            :starting_commit,
            :archive,
            :attachments,
            :build_system,
            :model_id_locked,
            :task_id,
            :node,
            :approval,
            :repo_less,
            :quality_level,
            :max_turns
          ],
          spelling <- [key, Atom.to_string(key)] do
        assert Validation.start_options("reflect", %{spelling => "safe", :objective => "Explain"}) ==
                 {:error, "Unsupported or duplicate option."}
      end

      assert {:error, "Expected a small options map."} =
               Validation.start_options("genesis", %{
                 path: "/repo",
                 mode: "new",
                 objective: "a",
                 prompt: "b",
                 model_id: "c",
                 extra: "d"
               })
    end
  end

  describe "start_options/2 text and path bounds" do
    test "requires nonblank valid UTF-8 without NUL for every supplied string" do
      for value <- ["", " \r\n\t", <<255>>, "a" <> <<0>> <> "b", nil, false, 12, [], %{}] do
        assert {:error, _} = Validation.start_options("reflect", %{objective: value})

        assert {:error, _} =
                 Validation.start_options("reflect", %{objective: "Explain", model_id: value})
      end

      assert {:error, _} = Validation.start_options("reflect", %{})
    end

    test "objective and prompt accept exactly 8000 bytes, not 8000 graphemes",
         %{tmp_dir: path} do
      for text <- [String.duplicate("x", 8_000), String.duplicate("é", 4_000)] do
        assert byte_size(text) == 8_000
        assert {:ok, :reflect, opts} = Validation.start_options("reflect", %{objective: text})
        assert opts[:objective] == text

        assert {:ok, :genesis, opts} =
                 Validation.start_options("genesis", %{path: path, prompt: text})

        assert opts[:prompt] == text
        assert opts[:objective] == text
        assert {:error, _} = Validation.start_options("reflect", %{objective: text <> "x"})

        assert {:error, _} =
                 Validation.start_options("genesis", %{path: path, prompt: text <> "x"})
      end
    end

    test "genesis mirrors prompt/objective with prompt precedence and preserves bytes",
         %{tmp_dir: path} do
      assert {:ok, :genesis, opts} =
               Validation.start_options("genesis", %{
                 path: path,
                 objective: "Objective",
                 prompt: " Prompt\n"
               })

      assert opts[:prompt] == " Prompt\n"
      assert opts[:objective] == " Prompt\n"

      assert {:ok, :genesis, opts} =
               Validation.start_options("genesis", %{path: path, objective: "Objective"})

      assert opts[:prompt] == "Objective"

      for {type, options} <- [
            {"reflect", %{objective: "Objective", prompt: "Prompt"}},
            {"evolve", %{path: path, objective: "Objective", prompt: "Prompt"}}
          ] do
        assert Validation.start_options(type, options) ==
                 {:error, "Only genesis tasks accept prompt."}
      end

      for key <- [:objective, :prompt] do
        assert {:error, _} =
                 Validation.start_options("extract_skills", %{key => "Extract", :path => path})
      end
    end

    test "reflect refuses even an existing absolute source path", %{tmp_dir: path} do
      assert Validation.start_options("reflect", %{path: path, objective: "Explain"}) ==
               {:error, "Reflect tasks do not accept a source path."}
    end

    test "requires an existing directory except for genesis new, and never creates it",
         %{tmp_dir: path} do
      missing = Path.join(path, "not-created")
      file = Path.join(path, "file.txt")
      File.write!(file, "not a directory")

      assert {:ok, :genesis, opts} =
               Validation.start_options("genesis", %{path: missing, objective: "Build"})

      assert opts[:path] == missing
      refute File.exists?(missing)

      for {type, extra} <- [
            {"genesis", %{mode: "existing", objective: "Build"}},
            {"evolve", %{objective: "Fix"}},
            {"extract_skills", %{}}
          ],
          invalid_path <- [missing, file, "relative/path", "~/repo", "", nil] do
        assert {:error, _} = Validation.start_options(type, Map.put(extra, :path, invalid_path))
      end

      assert {:ok, :evolve, opts} =
               Validation.start_options("evolve", %{path: Path.join(path, "."), objective: "Fix"})

      assert opts[:path] == Path.expand(path)
    end

    test "absolute genesis-new path has an exact 1024-byte ceiling", %{tmp_dir: root} do
      prefix = Path.join(root, "new-")
      path = prefix <> String.duplicate("x", 1_024 - byte_size(prefix))
      assert byte_size(path) == 1_024

      assert {:ok, :genesis, opts} =
               Validation.start_options("genesis", %{path: path, objective: "Build"})

      assert opts[:path] == path

      assert {:error, _} =
               Validation.start_options("genesis", %{path: path <> "x", objective: "Build"})

      for invalid_path <- [
            "relative",
            "../repo",
            "~/repo",
            "http://example.org/repo",
            "a" <> <<0>>,
            <<255>>
          ] do
        assert {:error, _} =
                 Validation.start_options("genesis", %{path: invalid_path, objective: "Build"})
      end
    end
  end

  describe "scheduler_options/1" do
    test "accepts inclusive numeric bounds for every atom and string key" do
      for {key, maximum} <- [
            default_llm_max_concurrency: 256,
            max_tool_concurrency: 256,
            max_turns: 10_000,
            max_turns_root: 10_000
          ],
          spelling <- [key, Atom.to_string(key)],
          value <- [1, div(maximum, 2), maximum] do
        assert Validation.scheduler_options(%{spelling => value}) == {:ok, [{key, value}]}
      end
    end

    test "normalizes mixed numeric keys without adding defaults or losing settings" do
      assert {:ok, opts} =
               Validation.scheduler_options(%{
                 "default_llm_max_concurrency" => 256,
                 "max_turns_root" => 10_000,
                 max_tool_concurrency: 1,
                 max_turns: 1
               })

      assert Keyword.keyword?(opts)
      assert length(opts) == 4

      assert Map.new(opts) == %{
               default_llm_max_concurrency: 256,
               max_tool_concurrency: 1,
               max_turns: 1,
               max_turns_root: 10_000
             }
    end

    test "rejects out-of-range integers and never coerces numeric values" do
      for {key, maximum} <- [
            default_llm_max_concurrency: 256,
            max_tool_concurrency: 256,
            max_turns: 10_000,
            max_turns_root: 10_000
          ],
          spelling <- [key, Atom.to_string(key)],
          value <- [
            -1,
            0,
            maximum + 1,
            1.0,
            maximum / 1,
            "1",
            Integer.to_string(maximum),
            nil,
            true,
            false,
            :infinity,
            [],
            %{}
          ] do
        assert {:error, message} = Validation.scheduler_options(%{spelling => value})
        assert message =~ "concurrency integers 1..256"
        assert message =~ "turn-cap integers 1..10000"
      end
    end

    test "paused accepts only a standalone boolean under either key spelling" do
      for spelling <- [:paused, "paused"], value <- [true, false] do
        assert Validation.scheduler_options(%{spelling => value}) == {:ok, [paused: value]}
      end

      for spelling <- [:paused, "paused"],
          value <- [nil, 0, 1, 1.0, "true", "false", "1", :yes, [], %{}] do
        assert {:error, message} = Validation.scheduler_options(%{spelling => value})
        assert message =~ "standalone boolean paused option"
      end

      for paused_key <- [:paused, "paused"],
          paused <- [true, false],
          key <- [
            :default_llm_max_concurrency,
            :max_tool_concurrency,
            :max_turns,
            :max_turns_root
          ],
          spelling <- [key, Atom.to_string(key)] do
        assert {:error, _} = Validation.scheduler_options(%{paused_key => paused, spelling => 1})
      end
    end

    test "rejects duplicate normalized keys even when both values agree" do
      for {key, value} <- [
            default_llm_max_concurrency: 1,
            max_tool_concurrency: 1,
            max_turns: 1,
            max_turns_root: 1,
            paused: true
          ],
          other <- [value, if(is_boolean(value), do: false, else: 2)] do
        assert {:error, _} =
                 Validation.scheduler_options(%{key => value, Atom.to_string(key) => other})
      end
    end

    test "rejects empty/non-map inputs and unknown keys alongside valid settings" do
      for options <- [%{}, nil, [], [max_turns: 1], "max_turns=1", 1, 1.0, true, false] do
        assert {:error, _} = Validation.scheduler_options(options)
      end

      for key <- [
            :model_profiles,
            :model_concurrency,
            :api_key,
            :node,
            :path,
            :default_tool_timeout,
            :max_tool_timeout,
            "MAX_TURNS",
            "max_turns ",
            "",
            1,
            nil,
            {:max_turns}
          ],
          spelling <- if(is_atom(key), do: [key, Atom.to_string(key)], else: [key]) do
        assert {:error, _} = Validation.scheduler_options(%{spelling => 1})
        assert {:error, _} = Validation.scheduler_options(%{spelling => 1, :max_turns_root => 1})
      end

      assert {:error, _} =
               Validation.scheduler_options(%{
                 default_llm_max_concurrency: 1,
                 max_tool_concurrency: 1,
                 max_turns: 1,
                 max_turns_root: 1,
                 paused: true,
                 extra: 1
               })
    end

    test "unknown input strings never become atoms" do
      key = "scheduler_option_not_an_atom_#{System.unique_integer([:positive])}"

      assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
      assert {:error, _} = Validation.scheduler_options(%{key => 1})
      assert {:error, _} = Validation.scheduler_options(%{key => true, :max_turns => 1})
      assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    end
  end

  describe "guide/2" do
    test "returns only the four payload fields and defaults to dismissible" do
      assert Validation.guide(" Look here\n", %{}) ==
               {:ok, %{message: " Look here\n", page: nil, selector: nil, dismissible: true}}

      assert Validation.guide("Look", %{
               "page" => "/tasks",
               "dismissible" => false,
               :selector => "#task-01_A"
             }) ==
               {:ok,
                %{message: "Look", page: "/tasks", selector: "#task-01_A", dismissible: false}}
    end

    test "accepts only known local pages, not URLs, traversal or query/fragment extensions" do
      for page <- [nil, "/", "/help", "/projects", "/tasks", "/agents", "/settings", "/system"] do
        assert {:ok, payload} = Validation.guide("Look", %{page: page})
        assert payload.page == page
      end

      for page <- [
            "https://example.org",
            "//example.org",
            "javascript:alert(1)",
            "/tasks?all=1",
            "/tasks#x",
            "/../tasks",
            "/tasks/",
            "/unknown",
            :tasks,
            1,
            %{}
          ] do
        assert {:error, _} = Validation.guide("Look", %{page: page})
      end
    end

    test "enforces the 2000-byte message ceiling and rejects invalid text" do
      for message <- [String.duplicate("a", 2_000), String.duplicate("é", 1_000)] do
        assert {:ok, %{message: ^message}} = Validation.guide(message, %{})
        assert {:error, _} = Validation.guide(message <> "a", %{})
      end

      for message <- ["", " \n\t", "x" <> <<0>>, <<255>>, nil, %{}, [], 1] do
        assert {:error, _} = Validation.guide(message, %{})
      end
    end

    test "simple selectors must start with an ASCII letter and fit exactly 80 bytes" do
      selector = "#a" <> String.duplicate("x", 78)
      assert {:ok, %{selector: ^selector}} = Validation.guide("Look", %{selector: selector})
      assert {:error, _} = Validation.guide("Look", %{selector: selector <> "x"})

      for selector <- ["#A_0-z", "#a", nil] do
        assert {:ok, _} = Validation.guide("Look", %{selector: selector})
      end

      for selector <- [
            "",
            "#",
            "#0id",
            "#_id",
            "#é",
            "#a b",
            "#a\n",
            "#a>b",
            "#a,body",
            "#a:hover",
            "[id=x]",
            "body",
            <<255>>,
            1,
            %{}
          ] do
        assert {:error, _} = Validation.guide("Look", %{selector: selector})
      end
    end

    test "rejects extra/duplicate options and nonboolean dismissibility" do
      for value <- [nil, "true", "false", 1, 0, :yes, []] do
        assert {:error, _} = Validation.guide("Look", %{dismissible: value})
      end

      for options <- [
            %{node: "remote"},
            %{html: "<script>"},
            %{message: "replacement"},
            %{:page => "/tasks", "page" => "/system"},
            %{:selector => "#a", "selector" => "#b"},
            %{:dismissible => true, "dismissible" => false},
            %{page: "/tasks", selector: "#a", dismissible: true, one: 1, two: 2, three: 3},
            nil,
            [],
            [page: "/tasks"]
          ] do
        assert {:error, _} = Validation.guide("Look", options)
      end
    end
  end
end
