---
name: boogy-custom-domains
description: Use when a tenant wants to serve a Boogy service on their own domain (app.theircompany.com) instead of the default platform subdomain — registering a custom domain, the DNS records to add, verification, root-serve semantics, and troubleshooting
---

# Custom domains

By default a deployed service is reachable at
`<handle>.<platform>/<service>/<path>`. A **custom domain** lets you serve
that service at your own brand domain — `app.theircompany.com`,
`api.wordle.example.io` — with no path prefix, from the domain root.

**v1 supports CNAME-able subdomains only.** Apex / root domains
(`theircompany.com`, which cannot CNAME) are not supported in this
version.

## One domain, one service, served at root

The binding model is: one custom domain maps to **exactly one service**,
and traffic to that domain hits the service at root (no `/<service>` path
segment). The domain becomes its own browser origin — cookies set by the
service are scoped to that domain.

A domain is globally unique on the platform: once a domain reaches
`verified` status it cannot be re-registered until removed.

**A custom domain serves at the origin root**, so the served index's injected
`<base href>` is `/` rather than a service mount. For a framework-built frontend
that removes the base-path question entirely: a build whose asset references are
root-absolute (`/assets/…`, `fetch("/api/…")`) resolves correctly here, because
the mount *is* the root.

It is not the only way to deploy such a build — a relative base
(Vite's `base: './'`) works at any mount on the tenant subdomain too, and an
author may also mount a service at `/`. A custom domain is the production
answer for a real app, not a workaround for a path problem. See
`boogy:boogy-serving-frontends`.

## Register a custom domain

```bash
boogy domain add app.theircompany.com --service my-service
```

### Choosing the service

The `--service` value is your service's **route segment** — the path prefix it's served under, which is the token appearing after your handle in a subdomain URL. For example, for a service at `<handle>.boogy.app/api/...`, the route segment is `api`. This is NOT necessarily the manifest `[service] id` (which might be a different name like `hello-api`). Passing the wrong value causes a silent 404 at serve time.

The platform mints an ownership token and returns **two DNS records** you
must create at your registrar:

| Type  | Name                              | Value                    |
|-------|-----------------------------------|--------------------------|
| CNAME | `app.theircompany.com`            | `cname.boogy.app`        |
| TXT   | `_boogy-challenge.app.theircompany.com` | `<token>`          |

- **CNAME** — routes traffic to the platform edge.
- **TXT** — proves you own the domain; the platform polls for it.

Both records must exist and propagate before the domain goes live.

> The CNAME target (`cname.boogy.app`) is a stable A-record we publish.
> Point your CNAME there and don't hard-code the IP — it may change.

## Verification (automatic)

After you create the DNS records, do nothing. A background verifier
polls the TXT record. When the token matches, the domain transitions to
`verified` and begins serving your service. A TLS certificate is issued
automatically at that point via on-demand issuance — no manual cert
management.

**`boogy domain list`** shows the current status of all your custom domains:

```
  DOMAIN                  SERVICE      STATUS
  ----------------------  -----------  ----------
  app.theircompany.com    my-service   pending_verification
```

Status values:
- `pending_verification` — waiting for the TXT record to resolve.
- `verified` — domain is live; your service serves at root.
- `disabled` — operator-disabled (contact support).

## Remove a custom domain

```bash
boogy domain remove app.theircompany.com
```

The binding is deleted immediately. The CNAME and TXT records at your
registrar can be removed as well. If the service is later deleted,
its custom-domain bindings are removed automatically (no dangling routes).

## Registration errors

| Error | Cause |
|-------|-------|
| `409 Conflict` | The domain is already registered and `verified`. |
| `404 Not Found` | The `--service` id does not exist or you do not own it. |
| `401 Unauthorized` | Token is missing or invalid — set `BOOGY_TOKEN`. |

## Troubleshooting

**Domain stuck in `pending_verification`**

The verifier polls the TXT record periodically (roughly every minute).
Common causes of a stuck pending state:

1. **TXT record missing or wrong.** Verify at your registrar that
   `_boogy-challenge.<your-domain>` has the exact token the CLI printed.
   Even a trailing space breaks the match.
2. **DNS not yet propagated.** TTLs on new records can take minutes to an
   hour depending on the registrar and resolver. Check with:
   ```bash
   dig TXT _boogy-challenge.app.theircompany.com
   ```
   Wait for the token to appear in the output before expecting the
   platform to verify.
3. **CNAME not created.** The CNAME is required for traffic routing and
   TLS issuance but NOT for the TXT verification step itself. A missing
   CNAME lets verification succeed but the service won't serve until the
   CNAME propagates too.
4. **Pending rows expire after 7 days.** If too much time passes, re-run
   `boogy domain add` to get a fresh token.

**404 after the domain shows `verified`**

- The service itself has not been deployed or was removed. Check
  `boogy list`.
- The service's ingress mode rejects the request (e.g. `authenticated`
  and no credential provided). Test with a `public` route first.

**TLS / certificate errors in the browser**

Certificate issuance happens automatically once verification completes.
If you see a cert error immediately after verification:

- The CNAME isn't propagated yet — wait a few minutes for propagation,
  then refresh (the cert issues on first HTTPS request to the domain).
- The domain was `disabled` — check `boogy domain list`.

You do NOT need to manage certificates; the platform handles issuance and
renewal for `verified` domains.

## "Sign in with Boogy" does not work on a custom domain

**A verified custom domain has no `/boogy/*` surface at all.** That whole path
segment — `/boogy/callback`, `/boogy/me`, `/boogy/logout`, `/boogy/config` — is
answered by the platform on a tenant subdomain and **refused** on a custom
domain, with the same 404 body an unmatched route gets. So the end-user sign-in
flow cannot complete there: there is nothing to exchange the authorization code
at, and no app-session cookie is ever set on your domain.

This is not a configuration you are missing. There is no allowed-redirect-origin
setting, and adding one would not help: the exchange binds a minted code to the
origin it was minted for by comparing that origin's own **DNS label**, and a
custom domain has no label to compare — deciding what one should stand for is an
origin-binding decision the platform has deliberately not taken yet.

What this means in practice:

| You want | Today |
|---|---|
| End-user sign-in on `app.theircompany.com` | **Not available.** Serve the signed-in part of the app on `<handle>.<base>` |
| An API on a custom domain called by a signed-in browser | Not via the app-session cookie — the cookie is host-only to the subdomain that set it and never travels to your domain |
| A public site, or one whose own routes need no end-user identity | Works normally |
| Programmatic callers (`sk_*` keys, workload/OBO credentials) | Work normally — the boundary is the browser sign-in flow, not authentication as such |

If you already serve a signed-in app on the platform subdomain, adding a custom
domain does not move the session onto it. Track this as a platform gap rather
than something to work around in your app: minting your own session on the
custom domain means re-implementing identity inside one tenant, which is the
anti-pattern `boogy:boogy-account-auth` names.

## Security model

- **Ownership via TXT:** only a party with DNS control over the domain
  can place the TXT token. This prevents a tenant from claiming a domain
  they do not own.
- **Path identity is the binding:** the `(owner, service)` pair comes
  from the domain registration, never from the URL path. Path manipulation
  cannot redirect to a different service.
- **Reserved domains blocked:** domains on the platform's own base domains
  cannot be registered as custom domains.

## Integration

- ← `boogy:deploying-boogy-services` — deploy the service first; custom
  domains attach to an existing `service_id`.
- → `boogy:boogy-auth` — the bound service's ingress mode applies
  normally on the custom domain, including per-route overrides.
- → `boogy:boogy-account-auth` — but read *"Sign in with Boogy" does not work
  on a custom domain* below first. There is no setting that enables it.
- → `boogy:boogy-serving-frontends` — how a framework-built frontend's base
  path interacts with the mount, on a custom domain and off it.
