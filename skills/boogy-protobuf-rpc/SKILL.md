---
name: boogy-protobuf-rpc
description: Use when a Boogy service must serve protobuf — gRPC, Connect, or gRPC-Web — from a .proto contract, or when deciding between protobuf and REST/JSON-RPC for an endpoint
---

# Boogy protobuf RPC

One mount serves **three wire protocols** — Connect, native gRPC, and
gRPC-Web — chosen by the caller's request content-type. You write one
handler per method and none of the framing.

**The host owns the wire; your guest owns the codec.** The host terminates
the transport, strips the length prefix / Connect envelope / compression,
and hands your handler the bare message; you decode it into a generated Rust
type and return one. Status travels back on reserved response headers the
host converts and strips. You never see a trailer, a frame, or a five-byte
prefix.

## Reach for it — or don't

**Do** when the contract is the point: an existing gRPC client you must
match, generated stubs in another language, service-to-service calls that
want a schema, or tooling that speaks reflection.

**Don't reach for it for speed.** Measured on this platform against the
*same handler* projected five ways, every protobuf arm is **slower** than
plain REST JSON, and native gRPC is the slowest of the five. The codec is
not where the difference lives — protobuf and JSON over the same transport
are a dead heat. What protobuf genuinely wins is **bytes on the wire**,
which is a smaller encoding rather than a cheaper one. If the ask is "make
this endpoint faster", protobuf is the wrong tool; see
`boogy:boogy-performance-and-scaling`.

**Streaming is not supported** — see the gap section below, and read it
before you design a method, because the refusal is at deploy time.

## The four pieces

Only the last two are code you write.

### 1. The `.proto`

`proto3`, with a package, so every service name is fully qualified.

```proto
syntax = "proto3";
package notes.v1;

message GetNoteRequest { string id = 1; }
message NoteReply      { string id = 1; string title = 2; }

service NotesService {
  rpc GetNote(GetNoteRequest) returns (NoteReply);
}
```

### 2. A `build.rs`

**No `protoc`, no `buf`, no toolchain to install.** The compiler is pure
Rust and runs as an ordinary build script.

```rust ignore-snippet: a build.rs, not guest code — it runs on the host at build time and boogy-proto-build is a build-dependency, absent from the guest dependency graph the snippet gate models
fn main() {
    boogy_proto_build::compile(&["proto/notes.proto"], &["proto"])
        .expect("compile notes.proto");
}
```

Cargo.toml, and both halves matter:

```toml
[dependencies]
boogy-sdk = { git = "https://github.com/Boogy-ai/boogy-sdk", rev = "<pin-rev>" }
# The wasm-safe protobuf runtime the generated message types use. The `json`
# feature is NOT optional: generated code references buffa's JSON helpers
# unconditionally, so without it the crate fails to compile whether or not
# you ever serve a JSON-codec request.
buffa = { version = "0.9", features = ["json"] }

[build-dependencies]
# Build-dependency ONLY — it pulls the protobuf codegen toolchain, which must
# never enter the wasm's own dependency graph. Take it from the SAME source
# and rev as your `boogy-sdk` entry above, exactly as you already do for
# `boogy-wit`.
boogy-proto-build = { git = "https://github.com/Boogy-ai/boogy-sdk", rev = "<pin-rev>" }
```

### 3. The `[grpc]` manifest block

```toml
[service]
id = "notes"
version = "0.1.0"
wasm = "target/wasm32-wasip2/release/notes.wasm"

[routing]
path = "/notes"
methods = ["GET", "POST"]

[grpc]
proto = "proto/notes.proto"
services = ["notes.v1.NotesService"]
# reflection = true  # the default
```

- **Not a capability.** Protobuf is an *inbound* surface, so nothing new is
  granted to your wasm and deny-by-default is untouched. Nothing goes in
  `[capabilities]` for this at all — the `[grpc]` block is the whole switch.
- **`services` must be fully qualified** (`notes.v1.NotesService`, not
  `NotesService`) — a bare name is rejected at manifest parse.
- **`[routing] methods` must include `POST`.** The gRPC wire is POST-only,
  and a `[grpc]` block without it is rejected at parse, not at runtime.
  `POST` is also *sufficient* — `methods = ["POST"]` is a complete manifest
  for a gRPC-only service. You do not add `GET` for the discovery endpoints
  below; those are answered by the platform, not your wasm, and are exempt
  from the method list the same way `openapi.json` is.
- A `[grpc]` block with an empty `services` list is simply off.

### 4. The mount and the handlers

```rust ignore-snippet: needs a build.rs-generated module to expand against — include_protos! and the notes::v1 message types do not exist without a compiled .proto
boogy_sdk::include_protos!();
// The generated PROTOBUF messages. Distinct from your #[derive(Model)] store
// structs: these describe the wire, those describe the table. Map between
// them in the handler — do not try to make one type do both jobs.
use notes::v1::{GetNoteRequest, NoteReply};
use boogy_sdk::grpc::{GrpcDispatcher, Response, RpcStatus};

Router::new()
    .info("Notes", env!("CARGO_PKG_VERSION"), Some("Notes over protobuf."))
    .grpc("notes.v1.NotesService", || {
        GrpcDispatcher::new("notes.v1.NotesService")
            .method("GetNote", get_note)
    });

fn get_note(_req: &mut Req<'_>, msg: GetNoteRequest) -> Result<Response<NoteReply>, RpcStatus> {
    // `Note` is the #[derive(Model)] struct, which owns Note::TABLE.
    let row = auth::load_owned(Note::TABLE, DEFAULT_OWNER_COL, &msg.id)
        .map_err(|e| RpcStatus::internal(e.to_string()))?
        .ok_or_else(|| RpcStatus::not_found("no such note"))?;
    Ok(Response::new(NoteReply {
        id: msg.id,
        title: row.text(Note::TITLE),
        ..Default::default()
    }))
}
```

`include_protos!()` splices in the generated messages — you never name the
codegen crate or a protobuf framework in your own source.

A method handler is `Fn(&mut Req<'_>, P) -> Result<Response<R>, RpcStatus>`
— deliberately the same shape as a JSON-RPC method, so the same business
logic can back REST, JSON-RPC and protobuf without reshaping. Because you
get a real `&mut Req<'_>`, guards, `Ctx`, `auth::current_principal()` and
`req.header(..)` all work exactly as they do in any other handler.

## Errors are `RpcStatus`, not `ApiError`

Constructors for the common codes: `not_found`, `invalid_argument`,
`permission_denied`, `internal`, `unimplemented`, and `unauthenticated` —
which is deliberately **message-free**, because an authentication failure
that explains itself is an enumeration oracle.

`with_detail(type_name, &message)` attaches a **structured** error detail:
protobuf's rich error model, a typed message packed for you rather than an
`Any` you hand-build. A validation failure naming the offending field, a
quota error carrying the limit and the reset time. Three things to know:

- **A detail on a successful status goes nowhere.** A success has no status
  message on the wire to carry it, so it is dropped, silently. Details are
  for failures.
- **A type name must be non-empty and must not contain `|`** (the wire
  separator). The SDK drops such a detail with a warning in your guest log
  rather than emitting a corrupted one — reachable if you forward an
  untrusted, caller-supplied type name unchecked, so don't.
- **Details are best-effort; code and message are not.** The platform caps
  both the number of details and their total encoded size on one response,
  because they ride as HTTP header values and an oversized header block
  costs the whole *connection* on some clients, not just the one call. Over
  the cap the overflow detail is dropped and **the RPC is still delivered**.
  Never put anything load-bearing in a detail that isn't also in the
  message.

On the success side, `Response::new(body)` (or `body.into()`) is the return
value; chain `.with_header(..)` / `.with_trailer(..)` when a *successful*
call needs to set metadata too — a pagination cursor, a rate-limit header, a
request id.

## What carries over unchanged

Everything that keys off headers rather than the wire, which is nearly
everything:

| | |
|---|---|
| Auth | Same PASETO / `sk_*` path. `auth::current_principal()` in the handler. |
| `[ingress]` mode + rate limits | Enforced before dispatch, identically to a REST route. |
| Delegation (OBO) | Unchanged; see `boogy:boogy-obo-delegation`. |
| Transactions | `tx` spans a protobuf handler and its cross-service calls the same way. |
| Capabilities | Unchanged, and protobuf grants none. |
| The request budget | Same wall-clock deadline; a protobuf handler is not special. |
| Caller headers | Reach you via `req.header(..)` — minus the identity-bearing ones the platform withholds from every guest (a platform token in `Authorization`, `Cookie`). A `sk_*` key your own service issued still arrives. |

## Discovery: reflection and the raw descriptor

With `reflection` on (the default) the platform serves, from the same mount:

- **gRPC server reflection** (both the current and the still-widely-used
  older service name, so `grpcurl`'s fallback path works), and
- **`GET <mount>/descriptor.bin`** — the compiled descriptor set verbatim,
  consumable as `grpcurl -protoset descriptor.bin ...` by a client that
  cannot or will not use reflection.

Both are answered by the platform without invoking your wasm, so they cost
you no instance slot and appear in no guest log.

**Their visibility is your `[ingress]` policy, with no separate switch.**
These requests pass auth and ingress evaluation before the platform answers
them, so on an `authenticated`-mode service an anonymous descriptor fetch is
already a 401 — and on a `public` service your `.proto` shape is public.
That is usually what you want from a typed contract; decide deliberately
rather than discovering it.

Your service also still auto-serves `openapi.json`, where the protobuf mount
appears as **one stub standing in for every method** — method routing is by
path, and reflection is the real method catalog. See
`boogy:boogy-api-specs`.

## Deploying

Build first, then deploy:

```bash
cargo build --target wasm32-wasip2 --release
boogy deploy boogy.toml
```

The build script writes the compiled descriptor into your crate; `boogy
deploy` finds it and ships it beside the wasm. Deploy without building and
the CLI stops with exactly that instruction rather than deploying a service
that cannot serve.

**Two ways a `[grpc]` deployment is refused with a 409, at provision, before
it ever becomes routable:**

1. `services` names something the compiled descriptor does not contain —
   usually a package/service-name typo between the manifest and the
   `.proto`.
2. A method is **streaming**.

Refusing at provision is the point. The alternative is activating a
deployment that mis-serves a streaming method as unary, which fails per
request, in production, at a moment nobody chose.

## The gap: streaming is not supported

**Client-streaming, server-streaming and bidirectional methods are all
refused.** Only unary is served. The `stream` keyword anywhere in a declared
service's methods makes the whole deployment a **provision-time 409** — the
deployment is not activated, and where a previous version exists the
platform restores it so your service keeps serving. The 409 body says
whether that restore succeeded; read it rather than assuming, because a
first-ever deploy has no previous version to fall back to.

*What to do instead*, in order of preference:

- **Drop `stream` and make the method unary.** Most "streaming" methods in a
  first draft are a paginated list; return a page and a cursor. See
  `boogy:boogy-access-patterns`.
- **Push instead of stream.** For server-to-client push, declare a channel
  and publish to it — `boogy:boogy-websockets`. For one caller and one
  request, a request-scoped stream returns immediately and the platform
  relays frames; see `boogy:boogy-capability-limits`.
- **Split the service.** Keep the streaming surface out of `[grpc] services`
  entirely — an undeclared service is not refused, it is simply not served
  over protobuf — and serve the unary methods over protobuf alongside.

## Availability: Connect works everywhere; native gRPC may not

Connect and gRPC-Web work over ordinary HTTP/1.1 and are reachable on any
deployment that serves protobuf at all. **Native gRPC needs HTTP/2 end to
end**, which needs a dedicated hostname on the deployment's edge, and that is
an operator decision that may not be enabled where you are deploying.

Practical consequence for an author: **do not make native gRPC the only way
to call your service.** Connect speaks the same methods, the same messages
and the same errors over ordinary HTTP/1.1, and a Connect client is the
portable default. If native gRPC is a hard requirement for a consumer, that
is a conversation with whoever operates the deployment before you design
around it.

### A native gRPC client also needs your service mounted at the root

**`[routing] path = "/"`, or an off-the-shelf gRPC client cannot reach you
at all.** This is unconditional, independent of the hostname question above,
and it is the constraint most likely to surprise you — the failure is a
transport-level error naming nothing about mounts:

```
Code: Unknown
Message: unexpected HTTP status code received from server: 200 (OK);
         transport: received unexpected content-type "application/octet-stream"
```

The platform serves the protobuf wire path *relative to your mount*
(`/<mount>/<pkg.Svc>/<Method>`). A native gRPC client builds its path as
`/<pkg.Svc>/<Method>` at the connection root and has **no mechanism to add a
prefix** — that is the gRPC wire convention itself, not a limitation of any
one client. Verified both ways against a real `grpcurl` on one fixture: the
same service that fails as above at `path = "/notes"` round-trips at
`path = "/"`.

Connect and gRPC-Web clients are configured with a base URL, so they reach a
mount-relative deployment normally. **Only native gRPC is affected.**

The example above mounts at `/notes`, which is the right default: it keeps
one owner subtree open for other services, and it costs you nothing unless a
consumer needs plain gRPC. The trade is real and belongs to you — a root
mount claims the whole owner subtree, so exactly one service per owner can
have it. Decide which of your services, if any, is the one that speaks
native gRPC.

## Charging for a method

A protobuf method can be priced by its fully-qualified name
(`grpc = "echo.v1.EchoService/Echo"`), so prices are per method rather than per
service — a read-only method can stay free beside an expensive one. The same rule
also prices a POST to that method's path, however the call arrives, so a caller
cannot pick a cheaper wire protocol to avoid a price.

Reflection and `descriptor.bin` are never charged: a caller must be able to
discover your surface without paying for it. See `boogy:boogy-route-pricing` for
choosing the numbers.

## Red flags

| Thought | Reality |
|---------|---------|
| "Protobuf will make this endpoint faster." | It will not. Measured against the same handler, every protobuf arm is slower than plain REST JSON here, and the codec is not the difference. Choose it for the contract, not the throughput. |
| "Serving protobuf must need its own capability grant." | It does not — there is no such capability, and adding an invented one to `[capabilities]` is a hard manifest parse failure (the schema rejects unknown keys). Protobuf is an inbound surface: the `[grpc]` block is the whole switch. |
| "I'll install protoc / add a buf step to CI." | Neither is needed or wanted. `build.rs` compiles the `.proto` in pure Rust; the author installs no toolchain. |
| "I'll use my generated message as my table type." | They are different jobs — the wire schema and the stored schema evolve for different reasons. Keep a `#[derive(Model)]` struct and map. See `boogy:boogy-data-modeling`. |
| "A streaming RPC will just fail at runtime for now." | It fails at **deploy**, with a 409, and the deployment never activates. Design the method as unary, or leave that service out of `[grpc] services`. |
| "`buffa` doesn't need the `json` feature — I only serve binary." | It does. Generated code references the JSON helpers unconditionally; without the feature the crate does not compile at all. |
| "I'll put the failure reason in an error detail." | Put it in the **message**. Details are capped in count and size and the overflow is dropped while the call still succeeds in being delivered — they are enrichment, never the only copy. |
| "`RpcStatus::ok().with_detail(..)` will attach context to a success." | A success carries no status message on the wire, so the detail is dropped silently. Use a response header or a field on the reply. |
| "Reflection is a debug feature, so it's fine to leave on a private service." | Reflection and `descriptor.bin` inherit the service's `[ingress]` policy — on a `public` service they publish your whole `.proto` shape. That's usually fine and sometimes not; decide, don't default. |
| "I'll hand-write the JSON endpoint too." | A Connect client sending JSON already reaches the same handler through the generated types' own JSON mapping. Writing a second path means keeping two in step. |

## Integration

- `boogy:boogy-rest-apis` — REST and JSON-RPC, the other two surfaces on the
  same router. A protobuf method and a JSON-RPC method have deliberately the
  same handler shape, so one function can back both.
- `boogy:boogy-api-specs` — what `openapi.json` says about a protobuf mount,
  and why there is no per-method spec document.
- `boogy:boogy-capability-limits` — the streaming gap in the context of
  every other platform gap, and the request-scoped stream alternative.
- `boogy:boogy-auth` — `RpcStatus::permission_denied` vs. the
  existence-masking `not_found`; ownership checks in a protobuf handler.
