defmodule EvoGit.Agent.Tools.WebRead do
  @moduledoc """
  Tool for reading web pages using Z.AI (zhipu.ai/chat.z.ai) Web Reader API.
  Note: Z.AI is a Chinese AI service provider.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "web_read",
      description:
        "Reads and parses the content of a web page. " <>
          "Returns the page content in markdown or text format.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "url" => %{
            "type" => "string",
            "description" => "The URL to retrieve"
          },
          "timeout" => %{
            "type" => "integer",
            "description" => "Request timeout in seconds (default 20)",
            "default" => 20
          },
          "no_cache" => %{
            "type" => "boolean",
            "description" => "Whether to disable caching (default false)",
            "default" => false
          },
          "return_format" => %{
            "type" => "string",
            "description" => "Return format: 'markdown' or 'text' (default markdown)",
            "default" => "markdown"
          },
          "retain_images" => %{
            "type" => "boolean",
            "description" => "Whether to retain images in the output (default true)",
            "default" => true
          }
        },
        "required" => ["url"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the web_read tool.
  """
  def execute(args, _repo_path, _repo_root) do
    with {:ok, url} <- Shared.fetch_string_arg(args, "url"),
         {:ok, timeout} <- validate_timeout(Map.get(args, "timeout", 20)),
         {:ok, no_cache} <- validate_boolean(Map.get(args, "no_cache", false), "no_cache"),
         {:ok, return_format} <-
           Shared.fetch_optional_string_arg(args, "return_format", "markdown"),
         {:ok, retain_images} <-
           validate_boolean(Map.get(args, "retain_images", true), "retain_images") do
      do_web_read(url, timeout, no_cache, return_format, retain_images)
    end
  end

  defp validate_timeout(value) when is_integer(value) and value >= 1, do: {:ok, value}

  defp validate_timeout(value),
    do: {:error, "Argument 'timeout' must be a positive integer, got: #{inspect(value)}"}

  defp validate_boolean(value, _name) when is_boolean(value), do: {:ok, value}

  defp validate_boolean(value, name),
    do: {:error, "Argument '#{name}' must be a boolean, got: #{inspect(value)}"}

  defp do_web_read(url, timeout, no_cache, return_format, retain_images) do
    api_key = System.get_env("ZAI_API_KEY")

    if is_nil(api_key) do
      "Error: ZAI_API_KEY environment variable is not set"
    else
      reader_url = "https://api.z.ai/api/paas/v4/reader"

      body = %{
        url: url,
        timeout: timeout * 1000,
        no_cache: no_cache,
        return_format: return_format,
        retain_images: retain_images
      }

      case Req.post(reader_url,
             json: body,
             auth: {:bearer, api_key},
             receive_timeout: :timer.seconds(timeout + 10)
           ) do
        {:ok, %{status: 200, body: response_body}} ->
          format_response(response_body)

        {:ok, %{status: status, body: response_body}} ->
          "Error: Web read failed with status #{status}. #{inspect(response_body)}"

        {:error, reason} ->
          "Error: Web read request failed: #{inspect(reason)}"
      end
    end
  end

  defp format_response(%{"reader_result" => result}) do
    title = result["title"] || "Untitled"
    url = result["url"] || ""
    content = result["content"] || ""
    description = result["description"] || ""

    header = "# #{title}\n\nSource: #{url}\n"

    description_str =
      if description != "" do
        "#{description}\n\n"
      else
        ""
      end

    header <> description_str <> content
  end

  defp format_response(response) do
    "Read response (unexpected format): #{inspect(response)}"
  end
end
