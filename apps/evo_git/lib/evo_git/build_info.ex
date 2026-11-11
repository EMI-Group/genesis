defmodule EvoGit.BuildInfo do
  @moduledoc "Immutable identity bundled with the runtime, independent of the caller's checkout."
  @unknown %{"revision" => "unknown", "release" => "unknown", "platform" => "unknown"}
  def get, do: read(Application.app_dir(:evo_git, "priv/mcp-build-info.json"))

  def read(path) do
    with {:ok, body} <- File.read(path),
         true <- byte_size(body) <= 16_384,
         {:ok, map} when is_map(map) <- Jason.decode(body),
         revision when is_binary(revision) <- map["revision"],
         true <- Regex.match?(~r/\A[0-9a-f]{40}\z/, revision),
         true <-
           Enum.all?(["release", "platform"], &(is_binary(map[&1]) and byte_size(map[&1]) <= 200)) do
      Map.take(map, ["revision", "release", "platform"])
    else
      _ -> @unknown
    end
  end
end
