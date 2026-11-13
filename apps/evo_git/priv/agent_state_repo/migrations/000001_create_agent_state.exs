defmodule EvoGit.AgentStateRepo.Migrations.CreateAgentState do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS agent_states (
      task_id TEXT NOT NULL,
      agent_id INTEGER NOT NULL,
      agent_module TEXT,
      depth INTEGER NOT NULL DEFAULT 0,
      parent_id INTEGER,
      node_path TEXT,
      repo_id TEXT,
      repo_less INTEGER NOT NULL DEFAULT 0,
      repo_root TEXT,
      custom_agent_id TEXT,
      mode TEXT,
      archive INTEGER NOT NULL DEFAULT 0,
      objective TEXT,
      model_spec TEXT,
      provider_profile_id TEXT,
      model_id TEXT,
      model_id_locked INTEGER NOT NULL DEFAULT 0,
      prompt_cache_key TEXT,
      llm_model TEXT,
      llm_context_window INTEGER,
      turn INTEGER NOT NULL DEFAULT 0,
      usage TEXT,
      total_tokens INTEGER NOT NULL DEFAULT 0,
      compression_count INTEGER NOT NULL DEFAULT 0,
      current_commit TEXT,
      phase TEXT,
      pending_inputs TEXT,
      format_version INTEGER NOT NULL DEFAULT 1,
      message_count INTEGER NOT NULL DEFAULT 0,
      chunk_count INTEGER NOT NULL DEFAULT 0,
      status TEXT NOT NULL DEFAULT 'running',
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      completed_at TEXT,
      PRIMARY KEY (task_id, agent_id)
    )
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS agent_state_chunks (
      task_id TEXT NOT NULL,
      agent_id INTEGER NOT NULL,
      seq INTEGER NOT NULL,
      message_count INTEGER NOT NULL,
      payload BLOB NOT NULL,
      inserted_at TEXT NOT NULL,
      PRIMARY KEY (task_id, agent_id, seq)
    )
    """)

    execute(
      "CREATE INDEX IF NOT EXISTS agent_states_status_completed_at_index " <>
        "ON agent_states (status, completed_at)"
    )

    execute("CREATE INDEX IF NOT EXISTS agent_states_updated_at_index ON agent_states (updated_at)")
  end

  def down do
    execute("DROP TABLE IF EXISTS agent_state_chunks")
    execute("DROP TABLE IF EXISTS agent_states")
  end
end
