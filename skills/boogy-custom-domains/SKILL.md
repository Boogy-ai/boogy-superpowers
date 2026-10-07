---
name: boogy-custom-domains
description: Use when a tenant wants to serve a Boogy service on their own domain (app.theircompany.com) as well as its own platform address — registering a custom domain, the DNS records to add, verification, root-serve semantics, and troubleshooting
---

# Custom domains

Every deployed service is reachable at the root of its own platform address,
`https://<name>-<suffix>.boogy.app/` (the `URL:` `boogy deploy` printed). A
**custom domain** lets you serve that service at your own brand domain too —
`app.theircompany.com`, `api.wordle.example.io` — also from the domain root.

**v1 supports CNAME-able subdomains only.** Apex / root domains
(`theircompany.com`, which cannot CNAME) are not supported in this
version.

## One domain, one service, served at root

The binding model is: one custom domain maps to **exactly one service**,
named by its service id, and traffic to that domain hits the service at root,
exactly as its own platform address does. The domain becomes its own browser
origin — cookies set by the service are scoped to that domain. A service with a
`[frontend]` is served there directly, at the root: the domain is an origin of
its own.

**Your domain becomes the address people see.** Once the domain is `verified`,
a person's top-level visit to a page on the service's platform address
(a navigation to an HTML document) is redirected to the same path on your
domain, so they meet one address, one storage and one sign-in. Everything else
keeps working on the platform address too: a Boards pane still frames it there
(frames are never redirected), and API calls, form posts and programmatic
clients are served on both hosts. A service whose frontend is `private = true`
is never redirected — the redirect would reveal the domain to a visitor its
ingress has not admitted.

A domain is globally unique on the platform: once a domain reaches
`verified` status it cannot be re-registered until removed.

**A custom domain serves at the origin root**, so the served index's injected
`<base href>` is `/`, exactly as on the service's own address. A relative base
(Vite's `base: './'`) works on both, and is still the right habit. See
`boogy:boogy-serving-frontends`.

## Register a custom domain

```bash
boogy domain add app.theircompany.com --service my-service
```

### Choosing the service

The `--service` value is your service's **id** — its manifest `[service] id`, as `boogy list` shows it (`service_id`). The domain serves that one service at its root, whatever its `[routing] path`. The service must already be deployed: an id you have not deployed is refused with `404 no_route_for_service`.

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
- `disabled` — the binding no longer serves: its service was deleted, or an
  operator disabled it. `boogy domain list` prints the reason and the command
  that binds it again.

## Remove a custom domain

```bash
boogy domain remove app.theircompany.com
```

The binding is deleted immediately. The CNAME and TXT records at your
registrar can be removed as well. **Deleting the service disables its
domains** (`boogy domain list` shows `disabled`, with the reason `service
deleted`), so a later service with the same id inherits none of them; run
`boogy domain add <domain> --service <id>` to bind one again.

## Registration errors

| Error | Cause |
|-------|-------|
| `409 Conflict` | The domain is already registered and `verified`. |
| `404 no_route_for_service` | You have no deployed service with that id. Deploy it first, then add the domain with its `[service] id`. |
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

## "Sign in with Boogy" on a custom domain

A verified custom domain is its one service's origin, and it runs the classic
sign-in itself: `/boogy/signin`, `/boogy/callback`, `/boogy/me`, `/boogy/renew`,
`/boogy/logout` and `/boogy/config` are all answered by the platform on your
domain (a guest's own router never sees a path under `/boogy/`). The session
lands as a host-only `__Host-boogy_app` cookie on your domain, for that one
service.

- **Start it with the SDK** (`boogy.connectApp('<owner>/<service>')`, which
  navigates the domain to its own `/boogy/signin`), or by hand —
  `boogy:boogy-account-auth`, "The classic flow". `app_origin` is your domain
  itself (`https://app.theircompany.com`), and the request names exactly ONE
  `aud`: the service the domain serves.
- **It signs in for the one service the domain is bound to.** `/authorize`
  refuses any other audience, and refuses sign-in while that service is not
  deployed.
- **Your app's own pages can see the sign-in.** A sign-in trip on a custom
  domain navigates through your own domain, so a service worker your page
  registers there could answer those navigations. That is your own users'
  trust in your own domain — the same as on the service's platform address.
- **The domain and the platform address are two origins**, each with its own
  session: signing in on one does not sign in the other. A person browsing
  lands on the domain (the redirect above); a Boards pane uses the platform
  address.
- **OAuth connections are the exception.** `/boogy/connections/callback` is not
  served on a custom domain: a provider redirects to the URI registered for the
  service's own platform address, so a connection's browser leg completes there
  and returns your user to the page they started on (`boogy:boogy-oauth-connections`).

| You want | Today |
|---|---|
| End-user sign-in on `app.theircompany.com` | Works, for the one service the domain serves |
| An API on a custom domain called by a signed-in browser from another origin | Not via the app-session cookie — it is host-only and only authenticates a same-origin request |
| A public site, or one whose own routes need no end-user identity | Works normally |
| Programmatic callers (`sk_*` keys, workload/OBO credentials) | Work normally |

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
- → `boogy:boogy-account-auth` — the classic sign-in flow a custom domain runs
  (see *"Sign in with Boogy" on a custom domain* above).
- → `boogy:boogy-serving-frontends` — serving a frontend, including a
  framework build's relative base, on a custom domain and off it.
