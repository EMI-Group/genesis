# DeepSeek

Use DeepSeek AI models through their OpenAI-compatible API.

## Overview

DeepSeek provides powerful language models including:

- **deepseek-chat** - General purpose conversational model
- **deepseek-reasoner** - Reasoning and problem-solving capabilities

## Prerequisites

1. Sign up at https://platform.deepseek.com/
2. Create an API key
3. Add the key to your environment:

   ```bash
   # .env
   DEEPSEEK_API_KEY=your-api-key-here
   ```

## Usage

### Basic Generation

Since DeepSeek models are not yet in the LLMDB catalog, use an inline model spec:

```elixir
# Using inline model spec (recommended)
{:ok, response} = ReqLLM.generate_text(
  %{provider: :deepseek, id: "deepseek-chat"},
  "Hello, how are you?"
)

# Or normalize first
model = ReqLLM.model!(%{provider: :deepseek, id: "deepseek-chat"})
{:ok, response} = ReqLLM.generate_text(model, "Hello!")
```

### Code Generation

```elixir
model = ReqLLM.model!(%{provider: :deepseek, id: "deepseek-reasoner"})

{:ok, response} = ReqLLM.generate_text(
  model,
  "Write a Python function to calculate fibonacci numbers",
  temperature: 0.2,
  max_tokens: 2000
)
```

### Streaming

```elixir
model = ReqLLM.model!(%{provider: :deepseek, id: "deepseek-chat"})

{:ok, stream} = ReqLLM.stream_text(model, "Tell me a story about space exploration")

for chunk <- stream do
  IO.write(chunk.text || "")
end
```

### With System Context

```elixir
context = ReqLLM.Context.new([
  ReqLLM.Context.system("You are a helpful coding assistant."),
  ReqLLM.Context.user("How do I parse JSON in Elixir?")
])

model = ReqLLM.model!(%{provider: :deepseek, id: "deepseek-reasoner"})

{:ok, response} = ReqLLM.generate_text(model, context)
```

## Helper Module

For convenience, create a wrapper module:

```elixir
defmodule MyApp.DeepSeek do
  def chat(prompt, opts \\ []) do
    model = ReqLLM.model!(%{provider: :deepseek, id: "deepseek-chat"})
    ReqLLM.generate_text(model, prompt, opts)
  end

  def think(prompt, opts \\ []) do
    model = ReqLLM.model!(%{provider: :deepseek, id: "deepseek-reasoner"})
    ReqLLM.generate_text(model, prompt, Keyword.merge([temperature: 0.2], opts))
  end

  def stream_chat(prompt, opts \\ []) do
    model = ReqLLM.model!(%{provider: :deepseek, id: "deepseek-chat"})
    ReqLLM.stream_text(model, prompt, opts)
  end
end

# Usage
MyApp.DeepSeek.chat("Explain quantum computing")
MyApp.DeepSeek.think("Write a React component for a todo list")
```

## Configuration

### Environment Variables

- `DEEPSEEK_API_KEY` - Required. Your DeepSeek API key

### Per-Request API Key

```elixir
ReqLLM.generate_text(
  %{provider: :deepseek, id: "deepseek-chat"},
  "Hello!",
  api_key: "sk-..."
)
```

## Available Models

| Model | Use Case | Context Window |
|-------|----------|----------------|
| `deepseek-chat` | General conversation, Q&A | 64K tokens |
| `deepseek-reasoner` | Complex reasoning tasks | 64K tokens |

Check https://platform.deepseek.com/docs for the latest model information.

## Troubleshooting

### `{:error, :not_found}` when using string spec

DeepSeek models are not yet in the LLMDB registry. Use an inline model spec instead:

```elixir
# ❌ Won't work (model not in LLMDB)
ReqLLM.generate_text("deepseek:deepseek-chat", "Hello!")

# ✅ Works (inline model spec)
ReqLLM.generate_text(
  %{provider: :deepseek, id: "deepseek-chat"},
  "Hello!"
)
```

### Authentication Errors

- Ensure `DEEPSEEK_API_KEY` is set in your `.env` file
- Check that the API key is valid at https://platform.deepseek.com/

### Rate Limits

DeepSeek API has rate limits. If you encounter rate limiting:
- Implement exponential backoff
- Consider batching requests
- Check your plan limits at https://platform.deepseek.com/

## Resources

- [DeepSeek Platform](https://platform.deepseek.com/)
- [DeepSeek API Documentation](https://platform.deepseek.com/docs)
- [Model Specs Guide](model-specs.md) - For more on inline model specifications
