---
name: boogy-llm-gateway
description: Use when a Boogy service needs to call an LLM — completions, tool use, model routing with fallback, bringing your own provider key, or streaming generated tokens to end users in real time
---

# Boogy LLM Gateway

A platform service at `boogy://_sys/services/llm-gateway` that your service
calls instead of talking to an LLM provider directly. It normalizes the
request and response across providers, routes a model *alias* to a provider
backend with fallback and retry, resolves the API key, and meters the tokens
so the spend lands on the right tenant.

Your service never holds a provider key or an SDK.

## When to use it

- Your service needs a completion, with or without tool use.
- You want the same request shape whether it runs on OpenAI or Anthropic.
- You want a fallback provider when the primary is rate-limited or down.
- You want to show tokens to a user as they are generated.

## Calling it

Mesh call from your service. The gateway's ingress is `internal`, so it is
reached over `peer`, not from a browser.

```
POST boogy://_sys/services/llm-gateway  /v1/complete
```

```json
{
  "model": "gpt-4o",
  "messages": [
    { "role": "system", "content": "You are terse." },
    { "role": "user", "content": "Summarize this in one line." }
  ],
  "max_tokens": 256
}
```

`model` is an **alias**, not a provider model id. The alias resolves to a
primary backend plus ordered fallbacks. `GET /v1/models` lists the aliases
your deployment has, with their per-1k input and output cost in micros.

The response is normalized, whichever provider served it:

```json
{
  "id": "...",
  "model": "gpt-4o",
  "provider": "openai",
  "choices": [
    { "message": { "role": "assistant", "content": "..." }, "finish_reason": "stop" }
  ],
  "usage": { "prompt_tokens": 11, "completion_tokens": 7, "total_tokens": 18 },
  "attempts": 1,
  "latency_ms": 402
}
```

`attempts` is the number of adapter calls actually made, so a `2` tells you a
retry or a fallback happened.

## Tool use

`tools` and `tool_choice` use the OpenAI shape and are translated for
providers that differ. A tool call comes back on the message:

```json
"choices": [{
  "message": {
    "role": "assistant",
    "content": null,
    "tool_calls": [{ "id": "call_1", "type": "function",
                     "function": { "name": "get_weather", "arguments": "{\"city\":\"NYC\"}" } }]
  },
  "finish_reason": "tool_calls"
}]
```

`arguments` is a JSON **string**, as in the OpenAI API — parse it yourself.

## Keys: bring your own, or use the platform's

Two scopes are tried, in order:

1. **Yours** — a secret bound under `(your-owner, "llm-gateway")`. Your spend,
   your rate limits, your provider account.
2. **The platform's** — used only if you have no binding **and** the provider
   is configured to allow it.

Your service never sees either key. It references a secret by name; the key is
injected at the wire edge outside your wasm. See `boogy-secrets` for binding
one.

## Errors

Every failure is `{"error": {"type": "<kind>", "message": "..."}}`. The `type`
is the stable part — switch on it, not on the message.

| `type` | HTTP | Means |
|---|---|---|
| `unknown_model` | 400 | The alias is not configured or is disabled |
| `bad_request` | 400, or 502 | 400 when the request was malformed or the provider rejected it; 502 when the provider's response could not be decoded |
| `context_length` | 400 | The prompt exceeded the model's window |
| `content_filter` | 400 | The provider refused on content grounds |
| `rate_limit` | 429 | The provider rate-limited us; retried and still limited |
| `timeout` | 504 | The attempt exceeded its per-attempt budget |
| `auth` | 502 | Key missing, invalid, or rejected |
| `upstream_5xx` | 502 | Provider fault |
| `missing_usage` | 502 | The provider returned a completion but no token counts |
| `all_backends_failed` | 502 | Every backend in the chain failed; the message names the last cause |
| `truncated` | 502 | A streamed response was cut before any terminal event |
| `too_large` | 502 | A streamed response exceeded the accumulation ceiling |

`missing_usage` is deliberate rather than lenient: a response with no token
counts cannot be priced, and accepting it would bill zero for tokens the
provider charges for. It fails loudly instead.

## Retries and fallback

Each alias carries a retry policy: `max_retries`, `backoff_ms`, and
`per_attempt_timeout_ms`. Retryable failures (`rate_limit`, `upstream_5xx`,
`timeout`) are re-attempted on the same backend with **exponential backoff and
jitter**, then the chain moves to the next backend. Non-retryable failures
(`auth`, `bad_request`, `context_length`) fail immediately without burning the
fallbacks.

Only a *successful* attempt is billed, so a retry never double-charges you.

## Streaming tokens to users

`stream: true` is **not supported** and returns 400. Instead, ask the gateway
to publish deltas to one of your service's websocket channels while the
request runs:

```json
{
  "model": "gpt-4o",
  "messages": [ ... ],
  "stream_to": { "channel": "llm", "principal": "<end-user>" }
}
```

The HTTP response is unchanged — you still get the complete
`CompletionResponse`. `stream_to` is a live side-channel, so adding it does
not change how you consume the result.

**Declare the channel in your manifest first.** For anything with more than one
end user, make it per-principal so one user's tokens cannot reach another's
subscriber:

```toml
[capabilities]
websockets = true

[[websockets.channels]]
name = "llm"
class = "principal"
```

Use `public` or `private` only when a single audience should see every stream.
See `boogy-websockets` for channel classes, grants, and the browser side.

A mismatch is refused with a 400 naming the fix, **before** the upstream call —
so a misaddressed stream costs no tokens:

- the caller is a user/agent token rather than a service (no manifest to
  declare a channel);
- the channel is not in your manifest, or `websockets` is off;
- a `principal` channel with no principal, or a principal on a broadcast
  channel.

### Frames

One JSON object per message. `request_id` identifies the completion and `seq`
is monotonic within it, so a client demultiplexes concurrent completions and
detects gaps.

```json
{"request_id":"r1","seq":0,"type":"delta","text":"Hello there"}
{"request_id":"r1","seq":1,"type":"reset"}
{"request_id":"r1","seq":2,"type":"end","ok":true,
 "usage":{"prompt_tokens":9,"completion_tokens":4,"total_tokens":13}}
```

- **`delta`** — append `text`; merge `tool_calls` by `index`.
- **`reset`** — the attempt that produced everything before it FAILED and is
  being retried. **Discard accumulated text for this `request_id`.** Skip this
  and you will show a retry's answer appended to one that never happened.
- **`end`** — terminal, always sent, on success and failure alike. `ok: false`
  carries `error`.

A client that handles those three, keyed by `request_id`, is complete.

### What to expect under load

Deltas are coalesced into frames rather than one message per token, because
the per-service websocket publish budget is shared with your own publishes and
per-token publishing would exhaust it on a single stream. Expect roughly **10
frames per second per active stream**, not one per token — size subscribers
and any fan-out for frames, not tokens.

Backpressure is absorbed rather than dropped: under pressure text arrives in
larger frames instead of vanishing.

## Limits

- `stream: true` on the HTTP response: not supported (400).
- The gateway is `internal` ingress — reach it over `peer`, not from a browser.
- Aliases, providers, costs, and retry policy are operator-configured; a
  service selects an alias but cannot change its routing.
