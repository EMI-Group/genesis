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

    TaskRegistry.add_recent_project(repo, "demo")

    ["demo-1", "demo-2"]
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
