defmodule EvoDash.DemoSeedRich do
  @moduledoc """
  Seeds a content-rich demo task (`demo-3`) into the demo repo created by
  `EvoDash.DemoSeed`: five commits touching a dozen files (adds, edits, one
  deletion) plus a long markdown agent summary — used to showcase the simple
  review UI at `/tree/review/demo-3`.

  Dev/demo use only (triggered via `GET /demo/seed`, after `DemoSeed.seed!/0`).
  """

  alias EvoGit.TaskInfo

  @task_id "demo-3"
  @branch "evogit/demo-3"

  @doc """
  Adds the rich branch + task record. Requires `EvoDash.DemoSeed.seed!/0` to
  have created the repo first. Returns the task id.
  """
  def seed! do
    repo = Path.join(System.user_home!(), "GenesisProjects/demo")

    git(repo, ["checkout", "main"])

    # legacy.py already exists on main (added by DemoSeed for the demo-4
    # refactor demo) — demo-3 deletes it again below.
    base_sha = rev_parse(repo, "HEAD")

    git(repo, ["checkout", "-b", @branch, "main"])

    apply_commit(repo, "feat: add Task model with status state machine", [
      {"src/models.py",
       """
       \"\"\"Task domain model.\"\"\"

       STATUSES = ("pending", "running", "done")
       PRIORITIES = ("low", "normal", "high")


       class Task:
           def __init__(self, id, title, priority="normal", due=None):
               self.id = id
               self.title = title
               self.priority = priority
               self.due = due
               self.status = "pending"

           def advance(self):
               idx = STATUSES.index(self.status)
               if idx < len(STATUSES) - 1:
                   self.status = STATUSES[idx + 1]
               return self.status

           def to_dict(self):
               return {
                   "id": self.id,
                   "title": self.title,
                   "priority": self.priority,
                   "due": self.due,
                   "status": self.status,
               }
       """},
      {"src/utils.py",
       """
       \"\"\"Shared helpers.\"\"\"

       from datetime import datetime


       def fmt_due(due):
           if not due:
               return ""
           return datetime.fromisoformat(due).strftime("%m-%d")


       def sort_by_priority(tasks):
           order = {"high": 0, "normal": 1, "low": 2}
           return sorted(tasks, key=lambda t: order[t.priority])
       """}
    ])

    apply_commit(repo, "feat: add REST api for tasks", [
      {"src/api.py",
       """
       \"\"\"Minimal REST API for the task board.\"\"\"

       from src.models import Task

       _TASKS = {}
       _NEXT_ID = [1]


       def list_tasks(status=None):
           tasks = [t.to_dict() for t in _TASKS.values()]
           if status:
               tasks = [t for t in tasks if t["status"] == status]
           return {"tasks": tasks}


       def get_task(task_id):
           task = _TASKS.get(task_id)
           if not task:
               return {"error": "not_found"}, 404
           return task.to_dict(), 200


       def create_task(title, priority="normal", due=None):
           task = Task(_NEXT_ID[0], title, priority, due)
           _TASKS[task.id] = task
           _NEXT_ID[0] += 1
           return task.to_dict(), 201


       def advance_task(task_id):
           task = _TASKS.get(task_id)
           if not task:
               return {"error": "not_found"}, 404
           task.advance()
           return task.to_dict(), 200


       def delete_task(task_id):
           if _TASKS.pop(task_id, None) is None:
               return {"error": "not_found"}, 404
           return {"deleted": task_id}, 200
       """}
    ])

    apply_commit(repo, "feat: kanban dashboard view with styling", [
      {"src/views/dashboard.html",
       """
       <!DOCTYPE html>
       <html lang="zh-CN">
       <head>
         <meta charset="utf-8" />
         <link rel="stylesheet" href="../static/style.css" />
         <title>任务看板</title>
       </head>
       <body>
         <main class="board">
           <section class="col" data-status="pending">
             <h2>待处理</h2>
             <div class="cards"></div>
           </section>
           <section class="col" data-status="running">
             <h2>进行中</h2>
             <div class="cards"></div>
           </section>
           <section class="col" data-status="done">
             <h2>已完成</h2>
             <div class="cards"></div>
           </section>
         </main>
       </body>
       </html>
       """},
      {"src/static/style.css",
       """
       .board { display: flex; gap: 16px; padding: 24px; }
       .col { flex: 1; background: #f6f7f9; border-radius: 10px; padding: 12px; }
       .col h2 { font-size: 13px; color: #555; margin-bottom: 10px; }
       .card { background: #fff; border: 1px solid #e3e5e8; border-radius: 8px;
               padding: 10px 12px; margin-bottom: 8px; }
       .card .prio-high { color: #c8383c; font-weight: 600; }
       .card .due { font-size: 11px; color: #999; margin-top: 4px; }
       """}
    ])

    apply_commit(repo, "test: cover all api endpoints", [
      {"tests/test_api.py",
       """
       from src.api import (list_tasks, get_task, create_task,
                            advance_task, delete_task)


       def setup_function(_):
           from src import api
           api._TASKS.clear()
           api._NEXT_ID[0] = 1


       def test_create_and_get():
           body, code = create_task("写周报", "high")
           assert code == 201
           fetched, code = get_task(body["id"])
           assert code == 200
           assert fetched["title"] == "写周报"


       def test_advance_flow():
           body, _ = create_task("修复登录")
           assert advance_task(body["id"])[0]["status"] == "running"
           assert advance_task(body["id"])[0]["status"] == "done"


       def test_list_filter():
           create_task("A")
           b, _ = create_task("B")
           advance_task(b["id"])
           assert len(list_tasks("pending")["tasks"]) == 1
           assert len(list_tasks("running")["tasks"]) == 1


       def test_delete():
           body, _ = create_task("C")
           assert delete_task(body["id"])[1] == 200
           assert get_task(body["id"])[1] == 404
       """}
    ])

    apply_commit(repo, "docs: usage guide, readme update, drop legacy module", [
      {"docs/usage.md",
       """
       # 使用说明

       ## 启动

       ```bash
       python -m src.api
       ```

       ## 看板

       打开 `src/views/dashboard.html`，任务按状态分三栏展示。

       ## API

       | 方法 | 路径 | 说明 |
       | ---- | ---- | ---- |
       | GET | /tasks | 任务列表（支持 ?status= 过滤） |
       | POST | /tasks | 创建任务 |
       | POST | /tasks/:id/advance | 推进状态 |
       | DELETE | /tasks/:id | 删除任务 |
       """},
      {"README.md",
       """
       # Demo Project

       A tiny project used to demo the Genesis simple-mode flow.

       ## Features

       - Task board: model + REST api + kanban view (see `src/`)
       - Unit tests in `tests/`
       - Usage guide in `docs/usage.md`
       """},
      {"CONTEXT.md",
       """
       # Demo Project Context

       ## Intent
       Demo playground repository (task board).

       ## Routing Table
       - `src/` → models / api / views / static
       - `tests/` → test files
       - `docs/` → guides
       """},
      {"src/legacy.py", :delete}
    ])

    tip_sha = rev_parse(repo, "HEAD")

    summary = """
    ## 任务完成总结

    本次任务交付了一个最小可用的**任务管理后台**，覆盖数据模型、HTTP API、页面渲染与样式、测试与文档五个层面。

    ### 主要变更

    1. **数据层**：`src/models.py` 定义 `Task` 数据模型（标题/状态/优先级/截止时间），支持状态机流转 `pending → running → done`；
    2. **API 层**：`src/api.py` 提供 5 个 REST 端点（列表/详情/创建/更新状态/删除），统一 JSON 错误格式；
    3. **页面层**：`src/views/dashboard.html` + `src/static/style.css` 实现看板视图，按状态分栏、卡片式展示；
    4. **工具层**：`src/utils.py` 提供日期格式化与优先级排序；
    5. **测试**：`tests/test_api.py` 覆盖全部端点共 12 个用例；
    6. **文档**：`docs/usage.md` 使用说明，`README.md` / `CONTEXT.md` 同步更新；
    7. **清理**：删除遗留文件 `src/legacy.py`。

    ### 验证结果

    - 12/12 测试通过
    - 手动冒烟：启动服务后看板正常渲染、状态流转正常

    共 5 个提交，变更 11 个文件。
    """

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    finished = DateTime.add(now, -300, :second)

    task = %TaskInfo{
      id: @task_id,
      type: :genesis,
      status: :completed,
      opts: [path: repo, prompt: "开发一个任务管理后台（演示任务）"],
      ref: nil,
      started_at: DateTime.add(finished, -900, :second),
      finished_at: finished,
      logs: [],
      result:
        {:ok,
         %{
           commit_sha: tip_sha,
           branch_name: @branch,
           result: summary,
           pr_url: nil,
           pr_title: nil
         }},
      review_status: :open,
      base_sha: base_sha,
      commit_sha: tip_sha,
      project_path: repo,
      branch_name: @branch,
      agent_count: 14,
      model_id: "demo-model"
    }

    # Leave the repo on main — merge-base(HEAD, branch) is used for the review
    # diff, and it degenerates when HEAD is the feature branch itself.
    git(repo, ["checkout", "main"])

    EvoGit.Store.put_task(EvoGit.Store, task)

    @task_id
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp apply_commit(repo, message, files) do
    for {rel, content} <- files do
      if content == :delete, do: File.rm!(Path.join(repo, rel)), else: write(repo, rel, content)
    end

    git(repo, ["add", "-A"])
    commit(repo, message)
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
