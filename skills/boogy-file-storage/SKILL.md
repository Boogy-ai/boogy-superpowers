---
name: boogy-file-storage
description: Use when a Boogy service needs to store or serve files — user uploads, avatars, images, documents, PDFs, video, generated exports or reports — or when asking where to put data too large for a table row
---

# Boogy File Storage

Boogy services store **rows** in their per-service store and **bytes** in
file collections. A row holds structured data; a file holds an image, a
PDF, a video, a generated CSV. Reach for `files` the moment the thing
you want to keep is not naturally a column.

## The one thing to internalise

> **Your service never carries the bytes.**

You mint an upload ticket and hand it to the client. The client sends the
bytes to a platform route. The platform serves them back. **No request
that reads a file runs your code at all** — which is why a file read
costs you no compute and no instance slot, and why an image-heavy app is
cheap here.

If you find yourself accepting a file body in a handler, buffering it, or
proxying it onward, stop: that design does not work on this platform (a
service instance is created fresh per request under a memory cap) and it
is not what the API asks for.

## Declare collections in the manifest

A **collection** is a named group of files with one access rule. Declare
every collection you use; an undeclared one fails closed.

```toml
[capabilities]
files = true

[files]
prefix = "files"          # where the platform mounts the byte routes

[[files.collections]]
name = "avatars"
access = "public"         # anyone; served with cache headers
max_bytes = "2MB"
content_types = ["image/png", "image/jpeg", "image/webp"]
inline_types  = ["image/png", "image/jpeg", "image/webp"]
cache_control = "public, max-age=31536000, immutable"

[[files.collections]]
name = "documents"
access = "principal"      # only the file's owner may read it
max_bytes = "50MB"

[[files.collections]]
name = "exports"
access = "private"        # reachable only through a URL you mint
max_bytes = "10MB"
```

`access` defaults to **private** if you omit it.

### The whole authorization rule

> A valid grant always suffices. Otherwise the collection's class decides.

| `access` | Who can read |
|---|---|
| `public` | anyone, no credential |
| `principal` | the authenticated principal that owns the file |
| `private` | nobody directly — only via a URL you mint |

You do not write authorization code for file reads. The platform enforces
this before your service is ever consulted.

## Uploading: one call

```rust
use boogy_sdk::files::Upload;

#[derive(Deserialize)]
struct StartUpload {
    size: u64,
}

#[derive(Serialize, schemars::JsonSchema)]
struct Ticket {
    url: String,
    method: String,
    key: String,
}

// Mint a ticket and return it to your client as JSON.
fn start_avatar_upload(req: &mut Req<'_>) -> Result<Json<Ticket>, ApiError> {
    let body: StartUpload = parse_body(req.body())?;
    let t = files_create_upload(
        "avatars",
        Upload::new().content_type("image/png").size_hint(body.size),
    )?;
    Ok(Json(Ticket { url: t.url, method: t.method, key: t.key }))
}
```

The client then sends the bytes to `t.url` with `t.method`.

**`t.url` is opaque.** The platform picks the transport by size — its own
route for small files, direct-to-storage for large ones — and your code
is identical either way. Do not parse it, rewrite it, or store it.

**Pass `size_hint` when you know it.** It lets an oversized upload be
refused at ticket time instead of after the client has sent everything.

**Omit `key` unless you need a specific name.** The default is a
platform-minted key: collision-free, non-enumerable, and impossible to
traverse with. Supplying your own is the escape hatch, and it is
validated (`/` is allowed as a separator; `..`, leading `/`, control
characters and non-normalised Unicode are refused).

## Serving: mint the URL at render time

```rust ignore-snippet: a two-line fragment — the key it reads and the handler's error type are not in scope in this block
let src = files_url("avatars", &key, None)?;          // public → permanent
let src = files_url("documents", &key, Some(300))?;   // otherwise → expiring
```

One call covers both cases. There is no grant type in the API because a
two-step "mint a token, then build a URL" protocol is easy to assemble
wrongly, and wrongly here means handing out access.

### Never store a URL

**This is the mistake to design against.** A URL for a non-public
collection expires; even a public one bakes in an origin that a custom
domain or a rename invalidates. Store the collection and key — or a
`FileRef`, which is exactly that pair and nothing else:

```rust
use boogy_sdk::files::FileRef;

#[derive(Model)]
struct Profile {
    id: String,
    avatar: Option<FileRef>,     // stores (collection, key), never a URL
}
```

Then mint the URL at render time, always fresh:

```rust ignore-snippet: a render fragment — the row it reads and the handler's error type are not in scope in this block
let src = profile.avatar.as_ref().map(|f| f.url(None)).transpose()?;
```

## Listing, metadata, deletion

```rust ignore-snippet: a call fragment — the key, the caller principal and the handler's error type are not in scope in this block
let info = files_stat("avatars", &key)?;                 // size, type, ready
let page = files_list("documents", Some(&me), None, 20)?; // one bounded page
files_delete("documents", &key)?;                        // immediate, permanent
```

On a `principal` collection the owner filter is **forced to the caller** —
you cannot accidentally list across users, and an unauthenticated caller
gets an empty page rather than everyone's files.

**Deletion is immediate and permanent.** Files are data, not schema:
there is no soft-drop and no revive, and rolling a deployment back does
not bring deleted bytes back. This differs from a dropped table column,
so do not carry that intuition across.

## Small files your service generates

```rust ignore-snippet: a call fragment — the generated bytes and the handler's error type are not in scope in this block
files_put_bytes("exports", "summary.csv", "text/csv", &csv)?;
let bytes = files_read_bytes("exports", "summary.csv")?;
```

For generated reports, thumbnails, or parsing a small uploaded CSV. Both
are **hard-capped** (a few MiB) and return `TooLarge` above it, so the
mistake surfaces while you are building rather than as an out-of-memory
failure in production. For anything user-sized, use a ticket.

Both are **refused inside a transaction** (`DeniedInTransaction`). A
transaction body may be retried, so it may hold no irreversible external
effect — the same rule that denies outbound HTTP and signing writes
there. Move the call outside `tx()`. Minting an upload ticket *is*
allowed in a transaction: it moves no bytes.

## Content types are a security control

An uploaded file is served from **your own origin**. If a user can upload
HTML or a scripted SVG and have it rendered there, they can run script
against your users' session.

The platform refuses the dangerous cases: executable types can never be
declared in `inline_types`, anything outside that list downloads instead
of rendering, and `nosniff` plus a sandbox policy are set on every
response. **Your part is to declare `content_types`.** A collection with
an explicit allowlist is the safe path, and it is the default you should
reach for.

## Errors

| Error | Meaning | Status |
|---|---|---|
| `TooLarge(n)` | over the collection's `max_bytes` or the inline cap | 413 |
| `UnsupportedContentType` | not in the collection's `content_types` | 415 |
| `QuotaExceeded` | the service is at its storage limit | 507 |
| `NotFound` | missing, or not yours — the two are indistinguishable | 404 |
| `NotReady` | the bytes have not arrived yet | 409 |
| `DeniedInTransaction` | move the call outside `tx()` | 409 |

`FilesError` converts into `ApiError`, so a bare `?` works in a handler.

## What files cost

Files add **no new billing dimension**. They land on three you already
have:

| Dimension | What files contribute |
|---|---|
| Storage | stored bytes, per GB-month, shared with your database rows |
| Egress | bytes served to clients |
| Requests | each file request |

**Compute and occupancy: zero.** Serving a file runs none of your code.

Storage is the one dimension that keeps charging when your traffic is
zero, so delete what you no longer need. Uploads that are started and
never completed hold quota until the platform expires them.

## Common mistakes

| Mistake | What to do instead |
|---|---|
| Accepting file bytes in a handler | Mint a ticket; the client uploads directly |
| Storing the result of `files_url` in a table | Store a `FileRef`; mint the URL when you render |
| Parsing or rewriting the ticket URL | Treat it as opaque and pass it through |
| Using `files_put_bytes` for user uploads | It is capped; use a ticket for anything user-sized |
| Writing your own permission check on file reads | Declare the collection's `access`; the platform enforces it |
| Leaving `content_types` off a collection that serves to browsers | Declare an allowlist |
| Expecting a deleted file to come back on rollback | It will not; deletion is permanent |
