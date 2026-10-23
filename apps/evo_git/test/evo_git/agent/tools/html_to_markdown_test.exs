defmodule EvoGit.Agent.Tools.HtmlToMarkdownTest do
  use ExUnit.Case, async: true

  alias EvoGit.Agent.Tools.HtmlToMarkdown

  describe "noise removal" do
    test "drops script, style, head, noscript, svg, comments, doctype and event handlers" do
      html = """
      <!DOCTYPE html>
      <html>
        <head><title>Ignored title</title><style>.x { color: red }</style></head>
        <body>
          <!-- a secret comment -->
          <h1>Kept heading</h1>
          <p onclick="alert(1)">Kept paragraph</p>
          <script>alert("nope")</script>
          <noscript>enable js</noscript>
          <svg><path d="M0 0"/></svg>
        </body>
      </html>
      """

      markdown = HtmlToMarkdown.convert(html)

      assert markdown == "# Kept heading\n\nKept paragraph"
      refute markdown =~ "Ignored title"
      refute markdown =~ "color: red"
      refute markdown =~ "alert"
      refute markdown =~ "secret comment"
      refute markdown =~ "enable js"
      refute markdown =~ "DOCTYPE"
    end

    test "an unclosed script swallows the rest of the document" do
      markdown = HtmlToMarkdown.convert("<p>before</p><script>var x = 1;")

      assert markdown == "before"
    end
  end

  describe "headings and blocks" do
    test "h1..h6 map to hash headings" do
      markdown =
        HtmlToMarkdown.convert(
          "<h1>one</h1><h2>two</h2><h3>three</h3><h4>four</h4><h5>five</h5><h6>six</h6>"
        )

      assert markdown ==
               "# one\n\n## two\n\n### three\n\n#### four\n\n##### five\n\n###### six"
    end

    test "paragraphs, divs and br become line breaks while runs of blank lines collapse" do
      markdown =
        HtmlToMarkdown.convert("<div>a</div><div>b</div><p>c<br>d</p><hr><p>e</p>")

      assert markdown == "a\n\nb\n\nc\nd\n\n---\n\ne"
      refute markdown =~ ~r/\n{3,}/
    end

    test "blockquote nesting prefixes each line" do
      markdown = HtmlToMarkdown.convert("<blockquote><p>quoted</p></blockquote><p>plain</p>")

      assert markdown == "> quoted\n\nplain"
    end
  end

  describe "lists" do
    test "unordered lists, including one nesting level" do
      markdown =
        HtmlToMarkdown.convert("<ul><li>one</li><li>two<ul><li>nested</li></ul></li></ul>")

      assert markdown == "- one\n- two\n  - nested"
    end

    test "ordered lists are numbered per list" do
      markdown =
        HtmlToMarkdown.convert("<ol><li>first</li><li>second</li><li>third</li></ol>")

      assert markdown == "1. first\n2. second\n3. third"
    end
  end

  describe "inline formatting" do
    test "strong/em/b/i become markdown emphasis" do
      markdown =
        HtmlToMarkdown.convert("<p><strong>bold</strong> <b>b</b> <em>it</em> <i>i</i></p>")

      assert markdown == "**bold** **b** *it* *i*"
    end

    test "inline code and pre blocks" do
      markdown = HtmlToMarkdown.convert("<p>run <code>mix test</code> now</p><pre>a\n  b</pre>")

      assert markdown == "run `mix test` now\n\n```\na\n  b\n```"
    end

    test "links resolve relative hrefs against the base url and keep absolute ones" do
      html = ~s(<p><a href="/rel?a=1&amp;b=2">rel</a> <a href="https://other.test/x">abs</a></p>)

      with_base = HtmlToMarkdown.convert(html, base_url: "https://example.com/dir/page")
      assert with_base == "[rel](https://example.com/rel?a=1&b=2) [abs](https://other.test/x)"

      without_base = HtmlToMarkdown.convert(html)
      assert without_base == "[rel](/rel?a=1&b=2) [abs](https://other.test/x)"
    end

    test "images become markdown images, resolving src against the base url" do
      markdown =
        HtmlToMarkdown.convert(~s(<img src="/pic.png" alt="a picture">),
          base_url: "https://x.test/"
        )

      assert markdown == "![a picture](https://x.test/pic.png)"
    end
  end

  describe "entities" do
    test "common named entities decode" do
      markdown =
        HtmlToMarkdown.convert(
          "<p>&amp; &lt; &gt; &quot; &#39; &mdash; &ndash; &hellip; &nbsp;|</p>"
        )

      assert markdown == "& < > \" ' — – … |"
    end

    test "numeric decimal and hex references decode, unknown names survive" do
      markdown = HtmlToMarkdown.convert("<p>&#65;&#x42; &notarealentity; &#x1F600;</p>")

      assert markdown == "AB &notarealentity; 😀"
    end
  end

  describe "tables" do
    test "flatten to one line per row" do
      markdown =
        HtmlToMarkdown.convert(
          "<table><tr><th>h1</th><th>h2</th></tr><tr><td>a</td><td>b</td></tr></table>"
        )

      assert markdown == "h1 | h2\na | b"
    end
  end

  describe "tolerance" do
    test "unclosed tags and stray closers never raise" do
      assert HtmlToMarkdown.convert("<p>open <b>bold") == "open **bold"
      assert HtmlToMarkdown.convert("</div></p>text") == "text"
      assert HtmlToMarkdown.convert("") == ""
      assert HtmlToMarkdown.convert("   \n  ") == ""
    end

    test "html? sniffs common markup and rejects plain text" do
      assert HtmlToMarkdown.html?("<!DOCTYPE html><html><body>hi</body></html>")
      assert HtmlToMarkdown.html?("<div>hi</div>")
      assert HtmlToMarkdown.html?("<p>hi")
      refute HtmlToMarkdown.html?("just some plain text\nwith lines")
      refute HtmlToMarkdown.html?("{\"json\": true}")
    end
  end
end
