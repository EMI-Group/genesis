defmodule EvoDashWeb.SettingsLive do
  use EvoDashWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <EvoDashWeb.Layouts.app flash={@flash} current_page={:settings} config_status={@config_status}>
      <div class="flex items-center gap-3 mb-2 animate-fade-in-up">
        <div class="bg-secondary/15 text-secondary p-3 rounded-xl">
          <.icon name="hero-cog-6-tooth" class="size-6" />
        </div>
        <div>
          <h1 class="text-xl font-bold">{gettext("Settings")}</h1>
          <p class="text-sm text-base-content/60">{gettext("Runtime configuration and file settings")}</p>
        </div>
      </div>

      <div class="mt-4 animate-fade-in-up animation-delay-100">
        <.tabs tabs={[%{id: "runtime", label: gettext("Runtime Settings")}, %{id: "config", label: gettext("Configuration File")}]} active={@active_tab} />
      </div>

      <%= if @active_tab == "runtime" do %>
        <div class="mt-4">
          <!-- Scheduler Pause/Resume Control -->
          <div class="bg-base-100 rounded-2xl shadow-sm border border-base-200 overflow-hidden animate-fade-in-up animation-delay-100">
            <div class="p-5 flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3 sm:gap-4">
              <div class="flex items-center gap-3">
                <div class={[
                  "p-3 rounded-xl",
                  if(@scheduler_paused, do: "bg-warning/15 text-warning", else: "bg-success/15 text-success")
                ]}>
                  <.icon name={if @scheduler_paused, do: "hero-pause-circle", else: "hero-play-circle"} class="size-6" />
                </div>
                <div>
                  <h2 class="text-base font-bold">
                    {if @scheduler_paused, do: gettext("Scheduler Paused"), else: gettext("Scheduler Active")}
                  </h2>
                  <p class="text-xs text-base-content/60">
                    <%= if @scheduler_paused do %>
                      {gettext("Running agents continue. No new slots or agents will be granted until resumed.")}
                    <% else %>
                      {gettext("Agents and slots are being granted normally.")}
                    <% end %>
                  </p>
                </div>
              </div>
              <button
                phx-click="toggle_pause"
                class={[
                  "btn",
                  if(@scheduler_paused, do: "btn-success", else: "btn-warning")
                ]}
              >
                <.icon name={if @scheduler_paused, do: "hero-play", else: "hero-pause"} class="size-4" />
                {if @scheduler_paused, do: gettext("Resume Scheduler"), else: gettext("Pause Scheduler")}
              </button>
            </div>
          </div>

          <!-- Config Status Warning -->
          <%= if not @config_status.ok? do %>
            <div class="mt-4 bg-warning/10 border border-warning/20 rounded-xl p-4">
              <h3 class="font-semibold text-warning flex items-center gap-2 mb-2">
                <.icon name="hero-exclamation-triangle" class="size-5" /> {gettext("Missing Configuration")}
              </h3>
              <ul class="space-y-1">
                <%= for warning <- @config_status.warnings do %>
                  <li class="text-sm text-warning/80 flex items-start gap-2">
                    <.icon name="hero-chevron-right" class="size-4 mt-0.5 shrink-0" />
                    <span>{warning}</span>
                  </li>
                <% end %>
              </ul>
              <p class="text-xs text-base-content/50 mt-2">
                {gettext("Set your LLM model in the scheduler settings below to resolve these issues.")}
              </p>
            </div>
          <% end %>

          <!-- Scheduler Settings Form -->
          <div class="mt-6 animate-fade-in-up animation-delay-200">
            <%= if is_nil(@scheduler_config[:llm_model]) do %>
              <div class="mb-4 bg-error/10 border border-error/20 rounded-xl p-4">
                <div class="flex items-start gap-3">
                  <.icon name="hero-exclamation-triangle" class="size-5 text-error shrink-0 mt-0.5" />
                  <div>
                    <h3 class="font-semibold text-error">{gettext("No LLM Model Configured")}</h3>
                    <p class="text-sm text-error/80 mt-1">
                      {gettext("Agents cannot run until you set a model. Fill in the LLM Model field below and click Save.")}
                    </p>
                    <p class="text-xs text-base-content/50 mt-2">
                      {gettext("Example model names:")} <code class="bg-base-200 px-1 rounded text-xs">anthropic/claude-sonnet-4-20250514</code>, <code class="bg-base-200 px-1 rounded text-xs">openai/gpt-4.1</code>
                    </p>
                    <p class="text-xs text-base-content/40 mt-1">
                      {gettext("Or set it in")} <code class="bg-base-200 px-1 rounded text-xs">~/.config/evogit/config.toml</code>: <code class="bg-base-200 px-1 rounded text-xs">llm_model = "provider/model"</code>
                    </p>
                  </div>
                </div>
              </div>
            <% end %>
            <EvoDashWeb.DashboardComponents.scheduler_settings config={@scheduler_config} />
          </div>

          <!-- Sandbox Settings -->
          <div class="mt-6 animate-fade-in-up animation-delay-250">
            <EvoDashWeb.DashboardComponents.sandbox_settings config={@scheduler_config} />
          </div>

          <!-- Current Config Summary -->
          <div class="mt-6 bg-base-100 rounded-2xl shadow-sm border border-base-200 overflow-hidden animate-fade-in-up animation-delay-300">
            <div class="p-4 sm:p-5 flex items-center gap-2">
              <div class="bg-info/15 text-info p-2 rounded-lg">
                <.icon name="hero-information-circle" class="size-4" />
              </div>
              <h2 class="text-base font-semibold">{gettext("Current Runtime Values")}</h2>
            </div>
            <div class="px-4 sm:px-5 pb-4 sm:pb-5">
              <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3 sm:gap-4">
                <% sandbox_backend = @scheduler_config[:sandbox_backend] %>
                <% base_values = [
                  {gettext("Status"), :paused, @scheduler_paused},
                  {gettext("LLM Concurrency"), :max_concurrency, @scheduler_config[:max_concurrency]},
                  {gettext("Tool Concurrency"), :max_tool_concurrency, @scheduler_config[:max_tool_concurrency]},
                  {gettext("Agent Max Retries"), :agent_max_retries, @scheduler_config[:agent_max_retries]},
                  {gettext("Max Depth"), :max_agent_depth, @scheduler_config[:max_agent_depth]},
                  {gettext("LLM Retries"), :max_retries, @scheduler_config[:max_retries]},
                  {gettext("LLM Model"), :llm_model, @scheduler_config[:llm_model]},
                  {gettext("Sandbox Mode"), :sandbox_mode, @scheduler_config[:sandbox_mode]},
                  {gettext("Sandbox Backend"), :sandbox_backend,
                    case sandbox_backend do
                      :systemd_run -> "systemd-run"
                      :sandbox_exec -> "sandbox-exec"
                      :none -> gettext("None")
                      _ -> gettext("Unknown")
                    end}
                ] %>
                <% resource_values = if sandbox_backend == :systemd_run do
                  [
                    {gettext("Slice CPU Quota"), :slice_cpu_quota, @scheduler_config[:sandbox_resources][:cpu_quota]},
                    {gettext("Slice Memory"), :slice_memory, @scheduler_config[:sandbox_resources][:memory_max]},
                    {gettext("Process CPU Quota"), :process_cpu_quota, @scheduler_config[:sandbox_process_resources][:cpu_quota]},
                    {gettext("Process Memory"), :process_memory, @scheduler_config[:sandbox_process_resources][:memory_max]}
                  ]
                else
                  []
                end %>
                <%= for {label, key, value} <- base_values ++ resource_values do %>
                  <div class="bg-base-200/40 rounded-lg p-3 border border-base-200">
                    <p class="text-xs text-base-content/50 font-medium uppercase tracking-wide">{label}</p>
                    <p class="text-sm font-mono mt-1">
                      <%= case value do %>
                        <% true -> %><span class="text-warning font-bold">{gettext("Paused")}</span>
                        <% false -> %><span class="text-success font-bold">{gettext("Active")}</span>
                        <% nil -> %><span class="text-base-content/30">{gettext("Not set")}</span>
                        <% v -> %><span>{v}</span>
                      <% end %>
                    </p>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        </div>
      <% end %>

      <%= if @active_tab == "config" do %>
        <div class="mt-4">
          <!-- Config File Status -->
          <div class="bg-base-100 rounded-2xl shadow-sm border border-base-200 overflow-hidden animate-fade-in-up p-4 sm:p-6">
            <div class="flex flex-col sm:flex-row sm:items-center gap-3">
              <div class="flex items-center gap-2 text-sm text-base-content/70">
                <.icon name="hero-document-text" class="size-5" />
                <span class="font-mono text-xs">{@config_path}</span>
              </div>
              <div class={[
                "badge badge-sm",
                if(@config_file_exists, do: "badge-success", else: "badge-warning")
              ]}>
                {if @config_file_exists, do: gettext("Exists"), else: gettext("Missing")}
              </div>
            </div>
            <%= if not @config_status.ok? do %>
              <div class="mt-3">
                <.config_status_badge status={@config_status} />
              </div>
            <% end %>
          </div>

          <.form for={%{}} phx-submit="save_file_config" class="mt-4 space-y-4">
            <!-- LLM Section -->
            <.collapsible_card id="config-llm" title={gettext("LLM")} icon="hero-sparkles" color={:primary} open={true}>
              <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
                <div class="form-control">
                  <label class="label">
                    <span class="label-text text-sm font-medium">{gettext("Model")}</span>
                  </label>
                  <input type="text" name="llm_model" value={@file_config[:llm][:model] || ""} placeholder={gettext("provider:model")} class="input input-bordered input-sm w-full" />
                  <label class="label">
                    <span class="label-text-alt text-base-content/50">{gettext("e.g. anthropic:claude-sonnet-4-20250514")}</span>
                  </label>
                </div>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text text-sm font-medium">{gettext("Compression Threshold Tokens")}</span>
                  </label>
                  <input type="number" name="llm_compression_threshold_tokens" value={@file_config[:llm][:compression_threshold_tokens] || ""} min="1000" step="1000" class="input input-bordered input-sm w-full" />
                </div>
              </div>
            </.collapsible_card>

            <!-- User Section -->
            <.collapsible_card id="config-user" title={gettext("User")} icon="hero-user" color={:info} open={true}>
              <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
                <div class="form-control">
                  <label class="label">
                    <span class="label-text text-sm font-medium">{gettext("GitHub Username")}</span>
                  </label>
                  <input type="text" name="user_github_username" value={@file_config[:user][:github_username] || ""} class="input input-bordered input-sm w-full" />
                </div>
              </div>
            </.collapsible_card>

            <!-- Scheduler Section -->
            <.collapsible_card id="config-scheduler" title={gettext("Scheduler")} icon="hero-cog-6-tooth" color={:secondary} open={true}>
              <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
                <div class="form-control">
                  <label class="label">
                    <span class="label-text text-sm font-medium">{gettext("Max Concurrency")}</span>
                  </label>
                  <input type="number" name="scheduler_max_concurrency" value={@file_config[:scheduler][:max_concurrency]} min="1" max="100" class="input input-bordered input-sm w-full" />
                </div>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text text-sm font-medium">{gettext("Max Tool Concurrency")}</span>
                  </label>
                  <input type="number" name="scheduler_max_tool_concurrency" value={@file_config[:scheduler][:max_tool_concurrency]} min="1" max="100" class="input input-bordered input-sm w-full" />
                </div>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text text-sm font-medium">{gettext("Agent Max Retries")}</span>
                  </label>
                  <input type="number" name="scheduler_agent_max_retries" value={@file_config[:scheduler][:agent_max_retries]} min="0" max="20" class="input input-bordered input-sm w-full" />
                </div>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text text-sm font-medium">{gettext("Max Agent Depth")}</span>
                  </label>
                  <input type="number" name="scheduler_max_agent_depth" value={@file_config[:scheduler][:max_agent_depth]} min="1" max="20" class="input input-bordered input-sm w-full" />
                </div>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text text-sm font-medium">{gettext("Max Retries")}</span>
                  </label>
                  <input type="number" name="scheduler_max_retries" value={@file_config[:scheduler][:max_retries]} min="1" max="100" class="input input-bordered input-sm w-full" />
                </div>
              </div>
            </.collapsible_card>

            <!-- Sandbox Section -->
            <.collapsible_card id="config-sandbox" title={gettext("Sandbox")} icon="hero-shield-check" color={:accent} open={false}>
              <!-- Backend Status Banner -->
              <div class="mb-4">
                <%= case @scheduler_config[:sandbox_backend] do %>
                  <% :systemd_run -> %>
                    <div class="flex items-center gap-2 p-3 rounded-lg bg-success/10 border border-success/20">
                      <span class="badge badge-success badge-sm">systemd-run</span>
                      <span class="text-sm text-success/80">{gettext("Full sandboxing: filesystem isolation, resource limits, syscall filtering")}</span>
                    </div>
                  <% :sandbox_exec -> %>
                    <div class="flex items-center gap-2 p-3 rounded-lg bg-warning/10 border border-warning/20">
                      <span class="badge badge-warning badge-sm">sandbox-exec</span>
                      <span class="text-sm text-warning/80">{gettext("Filesystem isolation only. Resource limits not available on macOS.")}</span>
                    </div>
                  <% _ -> %>
                    <div class="flex items-center gap-2 p-3 rounded-lg bg-error/10 border border-error/20">
                      <span class="badge badge-error badge-sm">{gettext("Not Available")}</span>
                      <span class="text-sm text-error/80">{gettext("No sandbox support on this platform. Commands run directly.")}</span>
                    </div>
                <% end %>
              </div>

              <div class="form-control mb-4">
                <label class="label">
                  <span class="label-text text-sm font-medium">{gettext("Mode")}</span>
                </label>
                <select name="sandbox_mode" class="select select-bordered select-sm w-full max-w-xs">
                  <option value="auto" selected={to_string(@file_config[:sandbox][:mode] || :auto) == "auto"}>{gettext("auto")}</option>
                  <option value="enabled" selected={to_string(@file_config[:sandbox][:mode] || :auto) == "enabled"}>{gettext("enabled")}</option>
                  <option value="disabled" selected={to_string(@file_config[:sandbox][:mode] || :auto) == "disabled"}>{gettext("disabled")}</option>
                </select>
              </div>

              <%= if @scheduler_config[:sandbox_backend] == :systemd_run do %>
                <h4 class="text-sm font-semibold text-base-content/70 mb-3 mt-2">{gettext("Slice Resources")}</h4>
                <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
                  <div class="form-control">
                    <label class="label">
                      <span class="label-text text-sm font-medium">{gettext("CPU Quota")}</span>
                    </label>
                    <input type="text" name="sandbox_resources_cpu_quota" value={@file_config[:sandbox][:resources][:cpu_quota] || ""} class="input input-bordered input-sm w-full" />
                  </div>
                  <div class="form-control">
                    <label class="label">
                      <span class="label-text text-sm font-medium">{gettext("CPU Weight")}</span>
                    </label>
                    <input type="number" name="sandbox_resources_cpu_weight" value={@file_config[:sandbox][:resources][:cpu_weight]} min="1" max="10000" class="input input-bordered input-sm w-full" />
                  </div>
                  <div class="form-control">
                    <label class="label">
                      <span class="label-text text-sm font-medium">{gettext("Memory Max")}</span>
                    </label>
                    <input type="text" name="sandbox_resources_memory_max" value={@file_config[:sandbox][:resources][:memory_max] || ""} class="input input-bordered input-sm w-full" />
                  </div>
                  <div class="form-control">
                    <label class="label">
                      <span class="label-text text-sm font-medium">{gettext("Tasks Max")}</span>
                    </label>
                    <input type="number" name="sandbox_resources_tasks_max" value={@file_config[:sandbox][:resources][:tasks_max]} min="1" class="input input-bordered input-sm w-full" />
                  </div>
                </div>

                <h4 class="text-sm font-semibold text-base-content/70 mb-3 mt-6">{gettext("Process Limits")}</h4>
                <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
                  <div class="form-control">
                    <label class="label">
                      <span class="label-text text-sm font-medium">{gettext("CPU Quota")}</span>
                    </label>
                    <input type="text" name="sandbox_process_cpu_quota" value={@file_config[:sandbox][:process][:cpu_quota] || ""} class="input input-bordered input-sm w-full" />
                  </div>
                  <div class="form-control">
                    <label class="label">
                      <span class="label-text text-sm font-medium">{gettext("Memory Max")}</span>
                    </label>
                    <input type="text" name="sandbox_process_memory_max" value={@file_config[:sandbox][:process][:memory_max] || ""} class="input input-bordered input-sm w-full" />
                  </div>
                  <div class="form-control">
                    <label class="label">
                      <span class="label-text text-sm font-medium">{gettext("Limit NOFILE")}</span>
                    </label>
                    <input type="number" name="sandbox_process_limit_nofile" value={@file_config[:sandbox][:process][:limit_nofile]} min="1" class="input input-bordered input-sm w-full" />
                  </div>
                  <div class="form-control">
                    <label class="label">
                      <span class="label-text text-sm font-medium">{gettext("OOM Score Adjust")}</span>
                    </label>
                    <input type="number" name="sandbox_process_oom_score_adjust" value={@file_config[:sandbox][:process][:oom_score_adjust]} min="-1000" max="1000" class="input input-bordered input-sm w-full" />
                  </div>
                </div>
              <% else %>
                <div class="bg-info/10 border border-info/20 rounded-lg p-3">
                  <p class="text-sm text-info/80">
                    <.icon name="hero-information-circle" class="size-4 inline-block mr-1" />
                    {gettext("Resource limits are only available on Linux with systemd-run. Only filesystem isolation is active on this platform.")}
                  </p>
                </div>
              <% end %>
            </.collapsible_card>

            <!-- Evolution Section -->
            <.collapsible_card id="config-evolution" title={gettext("Evolution")} icon="hero-arrow-path" color={:success} open={false}>
              <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
                <div class="form-control">
                  <label class="label">
                    <span class="label-text text-sm font-medium">{gettext("Pool Size")}</span>
                  </label>
                  <input type="number" name="evolution_pool_size" value={@file_config[:evolution][:pool_size]} class="input input-bordered input-sm w-full" />
                </div>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text text-sm font-medium">{gettext("Max Generations")}</span>
                  </label>
                  <input type="number" name="evolution_max_generations" value={@file_config[:evolution][:max_generations]} class="input input-bordered input-sm w-full" />
                </div>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text text-sm font-medium">{gettext("Selection Size")}</span>
                  </label>
                  <input type="number" name="evolution_selection_size" value={@file_config[:evolution][:selection_size]} class="input input-bordered input-sm w-full" />
                </div>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text text-sm font-medium">{gettext("Crossover Rate")}</span>
                  </label>
                  <input type="number" name="evolution_crossover_rate" value={@file_config[:evolution][:crossover_rate]} step="0.1" class="input input-bordered input-sm w-full" />
                </div>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text text-sm font-medium">{gettext("Mutation Rate")}</span>
                  </label>
                  <input type="number" name="evolution_mutation_rate" value={@file_config[:evolution][:mutation_rate]} step="0.1" class="input input-bordered input-sm w-full" />
                </div>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text text-sm font-medium">{gettext("Convergence Threshold")}</span>
                  </label>
                  <input type="number" name="evolution_convergence_threshold" value={@file_config[:evolution][:convergence_threshold]} step="0.001" class="input input-bordered input-sm w-full" />
                </div>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text text-sm font-medium">{gettext("Novelty Neighbors")}</span>
                  </label>
                  <input type="number" name="evolution_novelty_neighbors" value={@file_config[:evolution][:novelty_neighbors]} class="input input-bordered input-sm w-full" />
                </div>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text text-sm font-medium">{gettext("Stagnation Limit")}</span>
                  </label>
                  <input type="number" name="evolution_stagnation_limit" value={@file_config[:evolution][:stagnation_limit]} class="input input-bordered input-sm w-full" />
                </div>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text text-sm font-medium">{gettext("Initial Seed Count")}</span>
                  </label>
                  <input type="number" name="evolution_initial_seed_count" value={@file_config[:evolution][:initial_seed_count]} class="input input-bordered input-sm w-full" />
                </div>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text text-sm font-medium">{gettext("LLM Seed Count")}</span>
                  </label>
                  <input type="number" name="evolution_llm_seed_count" value={@file_config[:evolution][:llm_seed_count]} class="input input-bordered input-sm w-full" />
                </div>
              </div>
            </.collapsible_card>

            <!-- Truncation Section -->
            <.collapsible_card id="config-truncation" title={gettext("Truncation")} icon="hero-scissors" color={:warning} open={false}>
              <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
                <div class="form-control">
                  <label class="label">
                    <span class="label-text text-sm font-medium">{gettext("Tool Output Max Bytes")}</span>
                  </label>
                  <input type="number" name="truncation_tool_output_max_bytes" value={@file_config[:truncation][:tool_output_max_bytes]} class="input input-bordered input-sm w-full" />
                </div>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text text-sm font-medium">{gettext("Tool Output Default Max Bytes")}</span>
                  </label>
                  <input type="number" name="truncation_tool_output_default_max_bytes" value={@file_config[:truncation][:tool_output_default_max_bytes]} class="input input-bordered input-sm w-full" />
                </div>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text text-sm font-medium">{gettext("Tool Output Truncate Size")}</span>
                  </label>
                  <input type="number" name="truncation_tool_output_truncate_size" value={@file_config[:truncation][:tool_output_truncate_size]} class="input input-bordered input-sm w-full" />
                </div>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text text-sm font-medium">{gettext("Context Max Bytes")}</span>
                  </label>
                  <input type="number" name="truncation_context_max_bytes" value={@file_config[:truncation][:context_max_bytes]} class="input input-bordered input-sm w-full" />
                </div>
              </div>
            </.collapsible_card>

            <!-- Task History Section -->
            <.collapsible_card id="config-task-history" title={gettext("Task History")} icon="hero-clock" color={:info} open={false}>
              <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
                <div class="form-control">
                  <label class="label">
                    <span class="label-text text-sm font-medium">{gettext("Max Tasks")}</span>
                  </label>
                  <input type="number" name="task_history_max_tasks" value={@file_config[:task_history][:max_tasks]} class="input input-bordered input-sm w-full" />
                </div>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text text-sm font-medium">{gettext("Max Age Days")}</span>
                  </label>
                  <input type="number" name="task_history_max_age_days" value={@file_config[:task_history][:max_age_days]} class="input input-bordered input-sm w-full" />
                </div>
              </div>
            </.collapsible_card>

            <!-- Save Button -->
            <div class="flex justify-end pt-2 animate-fade-in-up">
              <button type="submit" class="btn btn-primary gap-2">
                <.icon name="hero-document-arrow-down" class="size-5" />
                {gettext("Save Configuration File")}
              </button>
            </div>
          </.form>
        </div>
      <% end %>
    </EvoDashWeb.Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "scheduler_config")
    end

    config_status = safe_config_status()
    config_path = EvoGit.Config.config_path()
    config_file_exists = File.exists?(config_path)
    file_config = load_file_config()

    socket =
      socket
      |> assign(:active_tab, "runtime")
      |> assign(:scheduler_config, load_scheduler_config())
      |> assign(:scheduler_paused, load_paused_state())
      |> assign(:config_status, config_status)
      |> assign(:file_config, file_config)
      |> assign(:config_path, config_path)
      |> assign(:config_file_exists, config_file_exists)

    {:ok, socket}
  end

  @impl true
  def handle_info({:scheduler_config_updated}, socket) do
    {:noreply,
     socket
     |> assign(:scheduler_config, load_scheduler_config())
     |> assign(:scheduler_paused, load_paused_state())}
  end

  @impl true
  def handle_event("select_tab", %{"id" => tab_id}, socket) do
    {:noreply, assign(socket, :active_tab, tab_id)}
  end

  @impl true
  def handle_event("scheduler_config_change", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("sandbox_config_change", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_pause", _params, socket) do
    if socket.assigns.scheduler_paused do
      EvoGit.AgentScheduler.resume()
      {:noreply,
       socket
       |> assign(:scheduler_paused, false)
       |> put_flash(:info, gettext("Scheduler resumed. New agents and slots are being granted."))}
    else
      EvoGit.AgentScheduler.pause()
      {:noreply,
       socket
       |> assign(:scheduler_paused, true)
       |> put_flash(:info, gettext("Scheduler paused. Running agents continue, but no new slots or agents will be granted."))}
    end
  end

  @impl true
  def handle_event("update_scheduler_config", params, socket) do
    config_updates =
      []
      |> maybe_add_int(:max_concurrency, params["max_concurrency"])
      |> maybe_add_int(:max_tool_concurrency, params["max_tool_concurrency"])
      |> maybe_add_int(:agent_max_retries, params["agent_max_retries"])
      |> maybe_add_int(:max_depth, params["max_agent_depth"])
      |> maybe_add_int(:max_retries, params["max_retries"])
      |> maybe_add_string(:llm_model, params["llm_model"])

    case EvoGit.AgentScheduler.update_config(config_updates) do
      :ok ->
        new_config = load_scheduler_config()
        had_no_model = is_nil(socket.assigns.scheduler_config[:llm_model])
        now_has_model = not is_nil(new_config[:llm_model])
        flash_msg =
          cond do
            had_no_model and now_has_model ->
              gettext("LLM model configured — agents are now available.")
            true ->
              gettext("Scheduler settings updated successfully.")
          end

        {:noreply,
         socket
         |> assign(:scheduler_config, new_config)
         |> put_flash(:info, flash_msg)}

      {:error, message} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Failed to update settings: %{message}", message: message))}
    end
  end

  @impl true
  def handle_event("update_sandbox_config", params, socket) do
    sandbox_mode =
      case params["sandbox_mode"] do
        "enabled" -> :enabled
        "disabled" -> :disabled
        _ -> :auto
      end

    # Slice-level resources
    resources =
      %{}
      |> maybe_add_string_to_map(:cpu_quota, params["cpu_quota"])
      |> maybe_add_int_to_map(:cpu_weight, params["cpu_weight"])
      |> maybe_add_string_to_map(:memory_max, params["memory_max"])
      |> maybe_add_int_to_map(:tasks_max, params["tasks_max"])

    # Per-process resources
    process_resources =
      %{}
      |> maybe_add_string_to_map(:cpu_quota, params["process_cpu_quota"])
      |> maybe_add_string_to_map(:memory_max, params["process_memory_max"])
      |> maybe_add_int_to_map(:limit_nofile, params["process_limit_nofile"])
      |> maybe_add_int_to_map(:oom_score_adjust, params["process_oom_score_adjust"])

    config_updates = [sandbox_mode: sandbox_mode, sandbox_resources: resources, sandbox_process_resources: process_resources]

    case EvoGit.AgentScheduler.update_config(config_updates) do
      :ok ->
        {:noreply,
         socket
         |> assign(:scheduler_config, load_scheduler_config())
         |> put_flash(:info, gettext("Sandbox settings updated successfully."))}

      {:error, message} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Failed to update sandbox settings: %{message}", message: message))}
    end
  end

  @impl true
  def handle_event("save_file_config", params, socket) do
    config = build_config_from_params(params)

    case EvoGit.Config.save_user_config(config) do
      :ok ->
        file_config = load_file_config()
        config_status = safe_config_status()
        config_file_exists = File.exists?(socket.assigns.config_path)

        {:noreply,
         socket
         |> assign(:file_config, file_config)
         |> assign(:config_status, config_status)
         |> assign(:config_file_exists, config_file_exists)
         |> put_flash(:info, gettext("Configuration file saved successfully."))}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Failed to save configuration: %{reason}", reason: inspect(reason)))}
    end
  end

  # Helpers

  defp load_file_config do
    try do
      EvoGit.Config.resolve()
    rescue
      _ -> %{}
    catch
      _, _ -> %{}
    end
  end

  defp safe_config_status do
    try do
      EvoGit.Config.config_status()
    rescue
      _ -> %{missing: [], warnings: [], ok?: true}
    catch
      _, _ -> %{missing: [], warnings: [], ok?: true}
    end
  end

  defp load_scheduler_config do
    try do
      EvoGit.AgentScheduler.get_config()
    rescue
      _ -> %{}
    catch
      _, _ -> %{}
    end
  end

  defp load_paused_state do
    try do
      EvoGit.AgentScheduler.get_config()[:paused] || false
    rescue
      _ -> false
    catch
      _, _ -> false
    end
  end

  defp build_config_from_params(params) do
    %{
      llm: %{
        model: empty_to_nil(params["llm_model"]),
        compression_threshold_tokens: parse_int(params["llm_compression_threshold_tokens"])
      },
      user: %{
        github_username: empty_to_nil(params["user_github_username"])
      },
      scheduler: %{
        max_concurrency: parse_int(params["scheduler_max_concurrency"]),
        max_tool_concurrency: parse_int(params["scheduler_max_tool_concurrency"]),
        agent_max_retries: parse_int(params["scheduler_agent_max_retries"]),
        max_agent_depth: parse_int(params["scheduler_max_agent_depth"]),
        max_retries: parse_int(params["scheduler_max_retries"])
      },
      sandbox: %{
        mode: parse_atom(params["sandbox_mode"]),
        resources: %{
          cpu_quota: empty_to_nil(params["sandbox_resources_cpu_quota"]),
          cpu_weight: parse_int(params["sandbox_resources_cpu_weight"]),
          memory_max: empty_to_nil(params["sandbox_resources_memory_max"]),
          tasks_max: parse_int(params["sandbox_resources_tasks_max"])
        },
        process: %{
          cpu_quota: empty_to_nil(params["sandbox_process_cpu_quota"]),
          memory_max: empty_to_nil(params["sandbox_process_memory_max"]),
          limit_nofile: parse_int(params["sandbox_process_limit_nofile"]),
          oom_score_adjust: parse_int(params["sandbox_process_oom_score_adjust"])
        }
      },
      evolution: %{
        pool_size: parse_int(params["evolution_pool_size"]),
        max_generations: parse_int(params["evolution_max_generations"]),
        selection_size: parse_int(params["evolution_selection_size"]),
        crossover_rate: parse_float(params["evolution_crossover_rate"]),
        mutation_rate: parse_float(params["evolution_mutation_rate"]),
        convergence_threshold: parse_float(params["evolution_convergence_threshold"]),
        novelty_neighbors: parse_int(params["evolution_novelty_neighbors"]),
        stagnation_limit: parse_int(params["evolution_stagnation_limit"]),
        initial_seed_count: parse_int(params["evolution_initial_seed_count"]),
        llm_seed_count: parse_int(params["evolution_llm_seed_count"])
      },
      truncation: %{
        tool_output_max_bytes: parse_int(params["truncation_tool_output_max_bytes"]),
        tool_output_default_max_bytes: parse_int(params["truncation_tool_output_default_max_bytes"]),
        tool_output_truncate_size: parse_int(params["truncation_tool_output_truncate_size"]),
        context_max_bytes: parse_int(params["truncation_context_max_bytes"])
      },
      task_history: %{
        max_tasks: parse_int(params["task_history_max_tasks"]),
        max_age_days: parse_int(params["task_history_max_age_days"])
      }
    }
    |> drop_nil_values()
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end
  defp parse_int(_), do: nil

  defp parse_float(value) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} -> float
      _ -> nil
    end
  end
  defp parse_float(_), do: nil

  defp parse_atom(value) when is_binary(value) and value != "" do
    String.to_atom(value)
  end
  defp parse_atom(_), do: nil

  # Recursively drop nil values from nested maps to avoid writing nils to TOML
  defp drop_nil_values(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {k, drop_nil_values(v)} end)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp drop_nil_values(value), do: value

  defp maybe_add_int(list, key, value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> Keyword.put(list, key, int)
      _ -> list
    end
  end

  defp maybe_add_int(list, _key, _value), do: list

  defp maybe_add_string(list, key, value) when is_binary(value) and value != "" do
    Keyword.put(list, key, value)
  end

  defp maybe_add_string(list, _key, _value), do: list

  defp maybe_add_int_to_map(map, key, value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> Map.put(map, key, int)
      _ -> map
    end
  end

  defp maybe_add_int_to_map(map, _key, _value), do: map

  defp maybe_add_string_to_map(map, key, value) when is_binary(value) and value != "" do
    Map.put(map, key, value)
  end

  defp maybe_add_string_to_map(map, _key, _value), do: map
end
