defmodule LLMDB.Dotenv do
  @moduledoc false

  def load!(opts \\ []) do
    if Application.get_env(:llm_db, :load_dotenv, true) do
      env_path = Keyword.get(opts, :path, Path.join(File.cwd!(), ".env"))

      if File.exists?(env_path) and not File.dir?(env_path) do
        env_path
        |> Dotenvy.source!()
        |> Enum.each(fn {key, value} ->
          if System.get_env(key) == nil do
            System.put_env(key, value)
          end
        end)
      end
    end

    :ok
  end
end
