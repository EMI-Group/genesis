defmodule EvoDash.DemoSeed do
  @moduledoc """
  Seeds a complete demo flow for the simple mode: a real git repo with two
  feature branches of agent-style commits plus matching completed task records
  in the store. The task ids (`demo-1` / `demo-2`) match the built-in
  `?demo=1` agent trees in `AgentsLive`, so the whole loop works:

      /tree?demo=1  →  (demo-1 / demo-2 tabs)  →  审查  →  /tree/review/demo-N

  Dev/demo use only (triggered via `GET /demo/seed`).
  """

  alias EvoGit.TaskInfo
  alias EvoGit.TaskRegistry

  @doc """
  Rebuilds the demo repo from scratch and (re)inserts the demo task records.
  Returns the list of seeded task ids.
  """
  def seed! do
    repo = Path.join(System.user_home!(), "GenesisProjects/demo")

    File.rm_rf!(repo)
    File.mkdir_p!(repo)

    git(repo, ["init", "-b", "main"])

    write(repo, "README.md", """
    # Demo Project

    A tiny project used to demo the Genesis simple-mode flow.
    """)

    write(repo, "CONTEXT.md", """
    # Demo Project Context

    ## Intent
    Demo playground repository.

    ## Routing Table
    - `src/` → source files
    - `tests/` → test files
    """)

    git(repo, ["add", "-A"])
    commit(repo, "chore: initial project scaffold")

    demo1_base = rev_parse(repo, "HEAD")

    demo1_tip =
      seed_task(repo, "main", demo1_base, %{
        task_id: "demo-1",
        branch: "evogit/demo-1",
        prompt: "做一个计算器（演示任务）",
        agent_count: 8,
        minutes_ago: 30,
        summary: """
        ## 任务完成总结

        已实现一个基础计算器：

        - `src/calculator.py`：加减乘除四个运算，除零抛出 `ValueError`
        - `tests/test_calculator.py`：4 个单元测试全部通过
        - `README.md`：补充了功能说明

        共 2 个提交，变更 3 个文件。
        """,
        commits: [
          {"feat: implement basic calculator operations",
           [
             {"src/calculator.py",
              """
              \"\"\"A minimal calculator.\"\"\"


              def add(a, b):
                  return a + b


              def sub(a, b):
                  return a - b


              def mul(a, b):
                  return a * b


              def div(a, b):
                  if b == 0:
                      raise ValueError("division by zero")
                  return a / b
              """}
           ]},
          {"test: add calculator tests and update docs",
           [
             {"tests/test_calculator.py",
              """
              from src.calculator import add, sub, mul, div


              def test_add():
                  assert add(2, 3) == 5


              def test_sub():
                  assert sub(10, 4) == 6


              def test_mul():
                  assert mul(3, 7) == 21


              def test_div():
                  assert div(8, 2) == 4
              """},
             {"README.md",
              """
              # Demo Project

              A tiny project used to demo the Genesis simple-mode flow.

              ## Features

              - Basic calculator: add / sub / mul / div (see `src/calculator.py`)
              - Unit tests in `tests/`
              """}
           ]}
        ]
      })

    seed_task(repo, demo1_tip, demo1_tip, %{
      task_id: "demo-2",
      branch: "evogit/demo-2",
      prompt: "给计算器增加幂运算（演示任务）",
      agent_count: 5,
      minutes_ago: 10,
      summary: """
      ## 任务完成总结

      在现有计算器基础上新增幂运算：

      - `src/calculator.py`：新增 `power(a, b)`
      - `tests/test_calculator.py`：补充对应测试

      共 1 个提交，变更 2 个文件。
      """,
      commits: [
        {"feat: add power operation with tests",
         [
           {"src/calculator.py",
            """
            \"\"\"A minimal calculator.\"\"\"


            def add(a, b):
                return a + b


            def sub(a, b):
                return a - b


            def mul(a, b):
                return a * b


            def div(a, b):
                if b == 0:
                    raise ValueError("division by zero")
                return a / b


            def power(a, b):
                return a ** b
            """},
           {"tests/test_calculator.py",
            """
            from src.calculator import add, sub, mul, div, power


            def test_add():
                assert add(2, 3) == 5


            def test_sub():
                assert sub(10, 4) == 6


            def test_mul():
                assert mul(3, 7) == 21


            def test_div():
                assert div(8, 2) == 4


            def test_power():
                assert power(2, 10) == 1024
            """}
         ]}
      ]
    })

    # demo-4: an evolve (refactor) demo for the old/new change trees on the
    # review page — branches from MAIN so merge-base stays tight (modified /
    # added / deleted statuses all show).
    git(repo, ["checkout", "main"])

    write(repo, "src/legacy.py", """
    \"\"\"Legacy helpers kept for reference (removed by the refactor demo).\"\"\"


    def old_entry():
        return "deprecated"
    """)

    git(repo, ["add", "-A"])
    commit(repo, "chore: add legacy helper module")

    demo4_base = rev_parse(repo, "HEAD")

    git(repo, ["checkout", "-b", "evogit/demo-4", "main"])

    write(repo, "README.md", """
    # Demo Project

    A tiny project used to demo the Genesis simple-mode flow.

    ## Features

    - Task board: model + REST api + kanban view (see `src/`)
    - Benchmark harness in `src/bench.py`
    """)

    write(repo, "CONTEXT.md", """
    # Demo Project Context

    ## Intent
    Demo playground repository (task board).

    ## Routing Table
    - `src/` → models / api / views / bench
    - `tests/` → test files
    - `docs/` → guides
    """)

    write(repo, "src/bench.py", """
    \"\"\"Tiny benchmark harness.\"\"\"

    import time


    def timeit(fn, *args, n=1000):
        start = time.perf_counter()
        for _ in range(n):
            fn(*args)
        return time.perf_counter() - start
    """)

    git(repo, ["rm", "src/legacy.py"])
    git(repo, ["add", "-A"])
    commit(repo, "refactor: add bench harness, update docs, drop legacy")

    demo4_tip = rev_parse(repo, "HEAD")

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    task = %EvoGit.TaskInfo{
      id: "demo-4",
      type: :evolve,
      status: :completed,
      opts: [path: repo, objective: "补充基准脚本并清理遗留模块（重构演示）"],
      ref: nil,
      started_at: DateTime.add(now, -120, :second),
      finished_at: now,
      logs: [],
      result:
        {:ok,
         %{
           commit_sha: demo4_tip,
           branch_name: "evogit/demo-4",
           result: "新增基准脚本，更新 README/CONTEXT，删除遗留模块。",
           pr_url: nil,
           pr_title: nil
         }},
      review_status: :open,
      base_sha: demo4_base,
      commit_sha: demo4_tip,
      project_path: repo,
      branch_name: "evogit/demo-4",
      agent_count: 4,
      model_id: "demo-model"
    }

    EvoGit.Store.put_task(EvoGit.Store, task)

    # Leave the repo on main so review merge-base diffs compute correctly.
    git(repo, ["checkout", "main"])

    # demo-5: genesis 视觉演示（图片生成器）—— 用于检查迷你任务树的生成效果
    git(repo, ["checkout", "-b", "evogit/demo-5", "main"])

    write(repo, "src/image_gen.py", """
    \"\"\"Placeholder image generator (demo).\"\"\"

    PALETTES = ("warm", "cool", "mono")


    def render(spec):
        \"\"\"Return an SVG placeholder for the given spec.\"\"\"
        palette = spec.get("palette", "warm")
        size = spec.get("size", (320, 200))
        return f'<svg width="{size[0]}" height="{size[1]}" data-palette="{palette}"/>'
    """)

    write(repo, "docs/design.md", """
    # 图片生成器设计说明

    - 输入：尺寸、配色、文案
    - 输出：SVG 占位图（后续替换为真实渲染）
    - 配色：warm / cool / mono 三套预设
    """)

    git(repo, ["add", "-A"])
    commit(repo, "feat: placeholder image generator with design notes")

    demo5_tip = rev_parse(repo, "HEAD")
    demo5_base = rev_parse(repo, "main")

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    task = %EvoGit.TaskInfo{
      id: "demo-5",
      type: :genesis,
      status: :completed,
      opts: [path: repo, prompt: "做一个图片生成器（视觉演示）"],
      ref: nil,
      started_at: DateTime.add(now, -90, :second),
      finished_at: now,
      logs: [],
      result:
        {:ok,
         %{
           commit_sha: demo5_tip,
           branch_name: "evogit/demo-5",
           result: "占位图片生成器：输入尺寸/配色/文案，输出 SVG 占位图，含设计说明。",
           pr_url: nil,
           pr_title: nil
         }},
      review_status: :open,
      base_sha: demo5_base,
      commit_sha: demo5_tip,
      project_path: repo,
      branch_name: "evogit/demo-5",
      agent_count: 8,
      model_id: "demo-model"
    }

    EvoGit.Store.put_task(EvoGit.Store, task)

    seed_ash("demo-5", 5, "做一个图片生成器（视觉演示）", [
      {101, nil, 0, EvoGit.Agents.CodebaseLead, "做一个图片生成器（视觉演示）", "5"},
      {102, 101, 1, EvoGit.Agents.Manager, "实现生成器", "5.1"},
      {103, 102, 2, EvoGit.Agents.Executor, "渲染核心", "5.1.1"},
      {104, 102, 2, EvoGit.Agents.Executor, "配色方案", "5.1.2"},
      {105, 104, 3, EvoGit.Agents.Executor, "预设调色板", "5.1.2.1"},
      {106, 101, 1, EvoGit.Agents.Manager, "文档与接口", "5.2"},
      {107, 106, 2, EvoGit.Agents.Executor, "设计说明", "5.2.1"},
      {108, 106, 2, EvoGit.Agents.Executor, "接口定义", "5.2.2"}
    ])

    # demo-6: evolve 修正对比演示（在图片生成器上修改/新增/删除）
    git(repo, ["checkout", "-b", "evogit/demo-6", "main"])

    write(repo, "src/image_gen.py", """
    \"\"\"Placeholder image generator (demo, v2).\"\"\"

    PALETTES = ("warm", "cool", "mono", "vivid")


    def render(spec):
        \"\"\"Return an SVG placeholder for the given spec.\"\"\"
        palette = spec.get("palette", "warm")
        size = spec.get("size", (320, 200))
        return f'<svg width="{size[0]}" height="{size[1]}" data-palette="{palette}"/>'
    """)

    write(repo, "src/palettes.py", """
    \"\"\"Palette presets.\"\"\"

    PRESETS = {
        "warm": ("#f5d0a9", "#c96f4a"),
        "cool": ("#a9c8f5", "#4a6fc9"),
        "mono": ("#d4d4d4", "#404040"),
        "vivid": ("#f5a9e1", "#8a2be2"),
    }
    """)

    git(repo, ["rm", "src/legacy.py"])
    git(repo, ["add", "-A"])
    commit(repo, "feat: vivid palette, extract presets, drop legacy")

    demo6_tip = rev_parse(repo, "HEAD")
    demo6_base = rev_parse(repo, "main")

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    task = %EvoGit.TaskInfo{
      id: "demo-6",
      type: :evolve,
      status: :completed,
      opts: [path: repo, objective: "抽出配色预设并清理遗留（修正对比演示）"],
      ref: nil,
      started_at: DateTime.add(now, -60, :second),
      finished_at: now,
      logs: [],
      result:
        {:ok,
         %{
           commit_sha: demo6_tip,
           branch_name: "evogit/demo-6",
           result: "配色抽到独立模块并新增 vivid 预设，删除遗留文件。",
           pr_url: nil,
           pr_title: nil
         }},
      review_status: :open,
      base_sha: demo6_base,
      commit_sha: demo6_tip,
      project_path: repo,
      branch_name: "evogit/demo-6",
      agent_count: 4,
      model_id: "demo-model"
    }

    EvoGit.Store.put_task(EvoGit.Store, task)

    seed_ash("demo-6", 6, "抽出配色预设并清理遗留（修正对比演示）", [
      {111, nil, 0, EvoGit.Agents.Manager, "抽出配色预设并清理遗留（修正对比演示）", "6"},
      {112, 111, 1, EvoGit.Agents.Executor, "配色模块", "6.1"},
      {113, 111, 1, EvoGit.Agents.Executor, "清理遗留", "6.2"}
    ])

    # Ash snapshots so the review pages' mini task tree has data in demos.
    seed_ash("demo-1", 1, "做一个计算器（演示任务）", [
      {1, nil, 0, EvoGit.Agents.CodebaseLead, "做一个计算器（演示任务）", "1"},
      {2, 1, 1, EvoGit.Agents.Manager, "实现计算器功能", "1.1"},
      {3, 2, 2, EvoGit.Agents.Executor, "四则运算", "1.1.1"},
      {4, 2, 2, EvoGit.Agents.Executor, "单元测试", "1.1.2"}
    ])

    seed_ash("demo-2", 2, "给计算器增加幂运算（演示任务）", [
      {11, nil, 0, EvoGit.Agents.Manager, "给计算器增加幂运算（演示任务）", "2"},
      {12, 11, 1, EvoGit.Agents.Executor, "幂运算实现", "2.1"},
      {13, 11, 1, EvoGit.Agents.Executor, "补充测试", "2.2"}
    ])

    seed_ash("demo-4", 4, "补充基准脚本并清理遗留模块（重构演示）", [
      {5, nil, 0, EvoGit.Agents.Manager, "补充基准脚本并清理遗留模块（重构演示）", "4"},
      {6, 5, 1, EvoGit.Agents.Executor, "基准脚本", "4.1"},
      {7, 5, 1, EvoGit.Agents.Executor, "文档更新与清理", "4.2"}
    ])

    TaskRegistry.add_recent_project(repo, "demo")

    ["demo-1", "demo-2", "demo-4", "demo-5", "demo-6"]
  end

  defp seed_ash(task_id, task_number, label, nodes) do
    agents =
      Enum.map(nodes, fn {id, parent_id, depth, mod, objective, local_id} ->
        %{
          id: id,
          parent_id: parent_id,
          task_id: task_id,
          task_number: task_number,
          task_local_id: local_id,
          status: "ash",
          live_status: :completed,
          depth: depth,
          agent_module: mod,
          objective: objective
        }
      end)

    EvoDash.AshTrees.put(%{
      task_id: task_id,
      task_number: task_number,
      label: label,
      size: length(agents),
      agents: agents
    })
  end

  # ── Private ──────────────────────────────────────────────────────────────

  # Creates the branch (from `start_ref`), applies the commits, inserts the
  # task record, and returns the branch tip SHA.
  defp seed_task(repo, start_ref, base_sha, spec) do
    git(repo, ["checkout", "-b", spec.branch, start_ref])

    for {message, files} <- spec.commits do
      for {rel, content} <- files, do: write(repo, rel, content)
      git(repo, ["add", "-A"])
      commit(repo, message)
    end

    tip_sha = rev_parse(repo, "HEAD")

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    finished = DateTime.add(now, -spec.minutes_ago * 60, :second)

    task = %TaskInfo{
      id: spec.task_id,
      type: :genesis,
      status: :completed,
      opts: [path: repo, prompt: spec.prompt],
      ref: nil,
      started_at: DateTime.add(finished, -180, :second),
      finished_at: finished,
      logs: [],
      result:
        {:ok,
         %{
           commit_sha: tip_sha,
           branch_name: spec.branch,
           result: spec.summary,
           pr_url: nil,
           pr_title: nil
         }},
      review_status: :open,
      base_sha: base_sha,
      commit_sha: tip_sha,
      project_path: repo,
      branch_name: spec.branch,
      agent_count: spec.agent_count,
      model_id: "demo-model"
    }

    EvoGit.Store.put_task(EvoGit.Store, task)

    tip_sha
  end

  defp write(repo, rel, content) do
    path = Path.join(repo, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp commit(repo, message) do
    git(repo, [
      "-c",
      "user.name=Genesis Demo",
      "-c",
      "user.email=demo@genesis.local",
      "commit",
      "-m",
      message
    ])
  end

  defp rev_parse(repo, ref) do
    {sha, 0} = git(repo, ["rev-parse", ref])
    String.trim(sha)
  end

  defp git(repo, args) do
    case System.cmd("git", args, cd: repo, stderr_to_stdout: true) do
      {out, 0} -> {out, 0}
      {out, code} -> raise "git #{Enum.join(args, " ")} failed (#{code}): #{out}"
    end
  end
end
