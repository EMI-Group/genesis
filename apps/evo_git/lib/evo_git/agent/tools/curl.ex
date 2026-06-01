defmodule EvoGit.Agent.Tools.Curl do
  @moduledoc """
  Tool for making HTTP requests using curl.
  Allows the agent to fetch web content or make API calls with full control over curl arguments.
  """

  alias EvoGit.Agent.Tools.Shared

  # 1 minute default timeout for curl requests
  @default_timeout 60_000

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "curl",
      description:
        "Makes an HTTP request using curl and returns the response body. " <>
          "Useful for fetching web pages, calling APIs, or retrieving any HTTP resource. " <>
          "Supports common HTTP methods (GET, POST, PUT, DELETE, etc.) and custom headers.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "url" => %{
            "type" => "string",
            "description" => "The URL to request (e.g., 'https://api.example.com/data')"
          },
          "method" => %{
            "type" => "string",
            "description" =>
              "HTTP method: GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS (default: GET)",
            "default" => "GET",
            "enum" => ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"]
          },
          "headers" => %{
            "type" => "object",
            "description" =>
              "Optional HTTP headers as a JSON object with key-value pairs. " <>
                "Example: {\"Authorization\": \"Bearer token123\", \"Content-Type\": \"application/json\", \"Accept\": \"application/json\"}",
            "additionalProperties" => %{"type" => "string"}
          },
          "body" => %{
            "type" => "string",
            "description" =>
              "Optional request body for POST/PUT/PATCH requests. " <>
                "For JSON APIs, pass a JSON string. Example: '{\"key\": \"value\"}'"
          },
          "max_bytes" => %{
            "type" => "integer",
            "description" =>
              "Maximum output size in bytes before truncation. " <>
                "Default: 16384 (16KB). Increase up to 131072 (128KB) if you need more output.",
            "default" => 16_384
          },
          "timeout" => %{
            "type" => "integer",
            "description" =>
              "Timeout in milliseconds for this tool execution. Default: #{@default_timeout}",
            "default" => @default_timeout
          }
        },
        "required" => ["url"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the curl tool.
  """
  def execute(args, _repo_path, _repo_root) do
    with {:ok, url} <- Shared.fetch_string_arg(args, "url"),
         {:ok, method} <- Shared.fetch_optional_string_arg(args, "method", "GET"),
         headers <- Map.get(args, "headers", %{}),
         body <- Map.get(args, "body") do
      do_curl(url, String.upcase(method), headers, body)
    end
  end

  defp do_curl(url, method, headers, body) do
    # Build curl command
    args = ["-s", "-S", "-X", method]

    # Add headers
    args =
      headers
      |> Enum.map(fn {k, v} -> ["-H", "#{k}: #{v}"] end)
      |> List.flatten()
      |> then(fn header_args -> args ++ header_args end)

    # Add body if provided
    args = if body, do: args ++ ["-d", body], else: args

    # Add URL with output limiting
    args = args ++ [url]

    # Use head to limit output size
    result = System.cmd("curl", args, stderr_to_stdout: true)

    case result do
      {output, 0} ->
        output

      {output, exit_code} ->
        "Error: curl exited with code #{exit_code}\n#{output}"
    end
  end
end
