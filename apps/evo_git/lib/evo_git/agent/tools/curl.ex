defmodule EvoGit.Agent.Tools.Curl do
  @moduledoc """
  Tool for fetching an HTTP resource or calling an HTTP API with `curl`.

  This is the HTTP escape hatch: it exposes full control over the method,
  headers, and body, and returns the response body (stderr folded in). It is
  also classified as a WRITE tool by `EvoGit.Agent.Tools` (an HTTP call may
  mutate remote state), so the repo-less and read-only-foreign-repo gates apply.

  ## Timeout contract

  `timeout` (ms) is HONOURED BY THE DISPATCHER, not by this module: the
  per-call timeout in `EvoGit.Agent.ToolDispatch` is read from the raw call
  args before the tool runs. This module therefore (a) injects its ADVERTISED
  default (60000 ms) into the args when the caller omitted `timeout`
  (`apply_defaults/1`) and (b) hands that value to curl as `--max-time`, so the
  documented default really bounds the request.

  `max_bytes` is likewise honoured outside this module: the output sanitizer
  (`EvoGit.Agent.OutputSanitizer`) reads `args["max_bytes"]` and truncates the
  returned text. This module neither reads nor rewrites it.
  """

  alias EvoGit.Agent.Tools.Failure
  alias EvoGit.Agent.Tools.Shared

  # The ADVERTISED per-call timeout (60s) — injected into the args when the
  # caller omits `timeout` and enforced on the curl subprocess (`--max-time`).
  @default_timeout 60_000

  # The dispatcher's hard per-call cap (`[:scheduler] max_tool_timeout`,
  # 30 minutes): a larger requested timeout is clamped to it there, so it is
  # clamped here too and the advertised contract stays honest.
  @max_timeout 1_800_000

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "curl",
      description:
        "Use the curl tool to fetch an HTTP resource or call an HTTP API when no dedicated tool fits. " <>
          "Returns the response body; supports GET/POST/PUT/DELETE/PATCH/HEAD/OPTIONS " <>
          "with custom headers and a request body. " <>
          "This is the HTTP escape hatch — prefer web_search to find information " <>
          "and read to fetch documentation when they suffice.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "url" => %{
            "type" => "string",
            "description" => "The absolute URL to request (e.g. 'https://api.example.com/data')."
          },
          "method" => %{
            "type" => "string",
            "description" => "HTTP method (default: GET).",
            "default" => "GET",
            "enum" => ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"]
          },
          "headers" => %{
            "type" => "object",
            "description" =>
              "Request headers as a JSON object of string values, " <>
                "e.g. {\"Authorization\": \"Bearer TOKEN\", \"Content-Type\": \"application/json\"}.",
            "additionalProperties" => %{"type" => "string"}
          },
          "body" => %{
            "type" => "string",
            "description" => "Request body for POST/PUT/PATCH; pass a JSON string for JSON APIs."
          },
          "max_bytes" => %{
            "type" => "integer",
            "description" => Shared.tool_output_limit_description(),
            "default" => 16_384
          },
          "timeout" => %{
            "type" => "integer",
            "description" =>
              "Per-call timeout in milliseconds (default: #{@default_timeout} = 60s, " <>
                "capped at #{@max_timeout} = 30 min).",
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
    args = apply_defaults(args)

    with {:ok, url} <- Shared.fetch_string_arg(args, "url"),
         {:ok, method} <- Shared.fetch_optional_string_arg(args, "method", "GET"),
         headers <- Map.get(args, "headers", %{}),
         body <- Map.get(args, "body"),
         timeout <- Map.get(args, "timeout") do
      do_curl(url, String.upcase(method), headers, body, timeout)
    end
  end

  @doc false
  # Arg-shaping seam for the advertised timeout contract (public solely so it
  # is unit-testable): injects `@default_timeout` when the caller omitted
  # `timeout` (or supplied a non-positive/non-integer value) and clamps a
  # supplied value to the dispatcher's `@max_timeout` hard cap.
  #
  # `max_bytes` is deliberately NOT touched — the output sanitizer owns that
  # cap and reads it from the original call args.
  #
  # Total: a non-map input is returned unchanged.
  def apply_defaults(args) when is_map(args) do
    case Map.get(args, "timeout") do
      timeout when is_integer(timeout) and timeout > 0 ->
        Map.put(args, "timeout", min(timeout, @max_timeout))

      _omitted_or_invalid ->
        Map.put(args, "timeout", @default_timeout)
    end
  end

  def apply_defaults(args), do: args

  defp do_curl(url, method, headers, body, timeout) do
    # Build curl command — `--max-time` bounds the request by this tool's own
    # timeout (the dispatcher's per-call timeout is computed from the RAW args
    # before the tool runs, so the tool's default must be enforced here too).
    args = ["-s", "-S", "-X", method, "--max-time", max_time_arg(timeout)]

    # Add headers
    args =
      headers
      |> Enum.map(fn {k, v} -> ["-H", "#{k}: #{v}"] end)
      |> List.flatten()
      |> then(fn header_args -> args ++ header_args end)

    # Add body if provided
    args = if body, do: args ++ ["-d", body], else: args

    # Add URL
    args = args ++ [url]

    result = System.cmd("curl", args, stderr_to_stdout: true)

    case result do
      {output, 0} ->
        output

      {output, exit_code} ->
        Failure.error("curl failed with exit code #{exit_code}.", output)
    end
  end

  # curl's own bound, in whole seconds rounded UP (so a 1500ms budget is
  # trimmed by the dispatcher, never by a silently shorter curl bound).
  defp max_time_arg(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    Integer.to_string(div(timeout_ms + 999, 1000))
  end

  defp max_time_arg(_timeout_ms), do: Integer.to_string(div(@default_timeout, 1000))
end
