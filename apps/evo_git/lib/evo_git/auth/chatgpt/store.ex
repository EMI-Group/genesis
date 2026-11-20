defmodule EvoGit.Auth.ChatGPT.Store do
  @moduledoc """
  Protected SIWC registrations for the local Genesis execution node.
  Profile references are names, so runtime configuration never contains tokens.
  """

  import Bitwise
  alias EvoGit.Auth.ChatGPT

  @default_account "default"
  @refresh_margin 60

  def default_account, do: @default_account
  def directory, do: Path.join(EvoGit.Platform.config_dir("genesis"), "chatgpt")

  def host_id do
    with_lock("host", fn ->
      path = Path.join(directory(), "host-id")

      case File.read(path) do
        {:ok, "urn:uuid:" <> _ = id} ->
          {:ok, id}

        {:error, :enoent} ->
          id = "urn:uuid:" <> Ecto.UUID.generate()
          with :ok <- atomic_write(path, id), do: {:ok, id}

        _ ->
          {:error, :invalid_host_id}
      end
    end)
  end

  def registration(account \\ @default_account) do
    case read(account) do
      {:ok, %{"client_id" => "oaiapp_" <> _, "subject" => subject} = record}
      when is_binary(subject) and subject != "" ->
        {:ok, Map.take(record, ["client_id", "subject"])}

      {:ok, _} ->
        {:error, :invalid_credentials}

      {:error, _} = error ->
        error
    end
  end

  def status(account \\ @default_account) do
    with {:ok, record} <- read(account),
         true <- ChatGPT.transferable?(record) do
      {:ok,
       %{
         expires: record["expires_at"] * 1000,
         account_id: account_label(record),
         models: cached_models(record)
       }}
    else
      false -> {:error, :no_credentials}
      {:error, _} = error -> error
    end
  end

  @doc "Lists connected registrations and cached model metadata for this execution node."
  def accounts do
    directory()
    |> File.ls()
    |> case do
      {:ok, files} ->
        for "account-" <> name <- files,
            String.ends_with?(name, ".json"),
            account = Path.rootname(name, ".json"),
            {:ok, status} <- [status(account)],
            into: %{} do
          {account, status}
        end

      {:error, _} ->
        %{}
    end
  end

  def token(account, model \\ nil) do
    with {:ok, record} <- read(account),
         :ok <- available(record, model) do
      if record["expires_at"] > System.system_time(:second) + @refresh_margin do
        {:ok, record["access_token"]}
      else
        with_lock("account-" <> account, fn ->
          with {:ok, current} <- read(account),
               :ok <- available(current, model),
               {:ok, refreshed} <- current_session(account, current) do
            {:ok, refreshed["access_token"]}
          end
        end)
      end
    end
  end

  def install(account, record) do
    with :ok <- valid_account(account),
         true <- ChatGPT.transferable?(record),
         {:ok, _} <- host_id() do
      with_lock("account-" <> account, fn ->
        with :ok <- compatible_registration(account, record),
             {:ok, record} <- verify_session(record),
             {:ok, models} <- ChatGPT.models(record["access_token"]),
             :ok <- save(account, Map.put(record, "models", models)) do
          {:ok, models}
        end
      end)
    else
      false -> {:error, :invalid_registration}
      {:error, _} = error -> error
    end
  end

  def import_file(account, path) do
    with {:ok, %{type: :regular, mode: mode, size: size}} <- File.stat(path),
         true <- :os.type() == {:win32, :nt} or (mode &&& 0o077) == 0,
         true <- size < 128_000,
         {:ok, json} <- File.read(path),
         {:ok, record} <- Jason.decode(json) do
      install(account, record)
    else
      _ -> {:error, :invalid_protected_file}
    end
  end

  def models(account \\ @default_account) do
    with :ok <- valid_account(account) do
      with_lock("account-" <> account, fn ->
        with {:ok, record} <- read(account),
             :ok <- available(record, nil),
             {:ok, current} <- current_session(account, record),
             {:ok, models} <- ChatGPT.models(current["access_token"]),
             :ok <- save(account, Map.put(current, "models", models)) do
          {:ok, models}
        end
      end)
    end
  end

  def logout(account \\ @default_account) do
    with :ok <- valid_account(account) do
      with_lock("account-" <> account, fn ->
        case read(account) do
          {:ok, record} ->
            result = if ChatGPT.transferable?(record), do: ChatGPT.revoke(record), else: :ok
            registration = Map.take(record, ["client_id", "subject", "issuer", "email"])

            case save(account, registration) do
              :ok when result == :ok -> :ok
              :ok -> {:error, :remote_revocation_unconfirmed}
              {:error, _} = error -> error
            end

          {:error, :no_credentials} ->
            :ok

          {:error, _} = error ->
            error
        end
      end)
    end
  end

  def path(account \\ @default_account) do
    with :ok <- valid_account(account),
         do: {:ok, Path.join(directory(), "account-" <> account <> ".json")}
  end

  defp compatible_registration(account, %{"client_id" => client_id, "subject" => subject}) do
    case registration(account) do
      {:ok, %{"client_id" => ^client_id, "subject" => ^subject}} -> :ok
      {:ok, _} -> {:error, :chatgpt_account_alias_in_use}
      {:error, reason} when reason in [:no_credentials, :invalid_credentials] -> :ok
      {:error, _} = error -> error
    end
  end

  defp account_label(%{"email" => email}) when is_binary(email), do: email
  defp account_label(record), do: record["subject"]

  defp cached_models(%{"models" => models}) when is_list(models) do
    for %{"slug" => slug, "display_name" => name} = model <- models,
        is_binary(slug) and is_binary(name),
        do: Map.take(model, ["slug", "display_name"])
  end

  defp cached_models(_), do: []

  defp available(record, model) do
    cond do
      not ChatGPT.transferable?(record) -> {:error, :no_credentials}
      is_nil(model) -> :ok
      Enum.any?(cached_models(record), &match?(%{"slug" => ^model}, &1)) -> :ok
      true -> {:error, :model_not_available_for_chatgpt_account}
    end
  end

  defp verify_session(record) do
    if record["expires_at"] > System.system_time(:second) + @refresh_margin do
      {:ok, record}
    else
      with {:ok, tokens} <- ChatGPT.refresh(record), do: {:ok, Map.merge(record, tokens)}
    end
  end

  defp current_session(account, record) do
    with {:ok, current} <- verify_session(record) do
      if current == record do
        {:ok, current}
      else
        with :ok <- save(account, current), do: {:ok, current}
      end
    else
      {:error, error} when error in [:reauthorization_required, :plan_not_authorized] ->
        with :ok <- save(account, Map.take(record, ["client_id", "subject", "issuer", "email"])) do
          {:error, error}
        end

      {:error, _} = error ->
        error
    end
  end

  defp read(account) do
    with {:ok, path} <- path(account),
         {:ok, content} <- File.read(path),
         {:ok, %{"client_id" => _, "subject" => _} = record} <- Jason.decode(content) do
      {:ok, record}
    else
      {:error, :enoent} -> {:error, :no_credentials}
      {:error, :invalid_account_alias} -> {:error, :invalid_account_alias}
      _ -> {:error, :invalid_credentials}
    end
  end

  defp save(account, record) do
    with {:ok, path} <- path(account), {:ok, json} <- Jason.encode(record) do
      atomic_write(path, json)
    end
  end

  @doc "Whether a value is safe as a registration alias."
  def valid_account?(account) when is_binary(account),
    do: Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}\z/, account)

  def valid_account?(_), do: false

  defp valid_account(account) do
    if valid_account?(account), do: :ok, else: {:error, :invalid_account_alias}
  end

  # The lock also covers standalone release commands using the same directory.
  # The runtime obtains it only for credential changes or token refresh.
  defp with_lock(name, fun) do
    dir = directory()
    lock = Path.join(dir, name <> ".lock")

    with :ok <- prepare_directory(dir),
         :ok <- acquire(lock, System.monotonic_time(:millisecond) + 20_000) do
      try do
        fun.()
      after
        File.rmdir(lock)
      end
    end
  end

  defp prepare_directory(dir) do
    with :ok <- File.mkdir_p(dir), do: File.chmod(dir, 0o700)
  end

  defp acquire(path, deadline) do
    case File.mkdir(path) do
      :ok ->
        :ok

      {:error, :eexist} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(50)
          acquire(path, deadline)
        else
          {:error, :chatgpt_account_busy}
        end

      {:error, _} ->
        {:error, :chatgpt_store_unwritable}
    end
  end

  defp atomic_write(path, content) do
    temp = path <> "." <> Ecto.UUID.generate() <> ".tmp"

    try do
      with :ok <- File.write(temp, "", [:exclusive]),
           :ok <- File.chmod(temp, 0o600),
           :ok <- File.write(temp, content),
           :ok <- File.rename(temp, path) do
        :ok
      else
        {:error, _} -> {:error, :chatgpt_store_unwritable}
      end
    after
      File.rm(temp)
    end
  end
end
