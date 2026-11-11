defmodule EvoGit.BuildInfoTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir
  test "reports packaged identity and ignores unrelated metadata", %{tmp_dir: tmp} do
    file = Path.join(tmp, "build.json")

    File.write!(
      file,
      Jason.encode!(%{
        revision: String.duplicate("a", 40),
        release: "mcp-preview-0.6.0",
        platform: "windows_x64",
        secret: "do-not-return"
      })
    )

    assert EvoGit.BuildInfo.read(file) == %{
             "revision" => String.duplicate("a", 40),
             "release" => "mcp-preview-0.6.0",
             "platform" => "windows_x64"
           }

    File.write!(file, "invalid")
    assert EvoGit.BuildInfo.read(file)["revision"] == "unknown"
    assert EvoGit.BuildInfo.read(Path.join(tmp, "absent"))["revision"] == "unknown"
  end
end
