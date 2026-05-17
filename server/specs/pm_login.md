# PM Login: Self-Hosted Sign-In for Fulfilled

The user's framing is one sentence: *"the back end URL is dynamic, per
client for mobile applications."* That sentence converts the login
screen from a routine three-field form into a small product problem,
because the field that matters most on a self-hosted app — the server
URL — has no good default the app can ship. Every other self-hosted
mobile app the user might compare us to (Mastodon, Bitwarden, Element,
NextCloud, Jellyfin, Plex, Outlook-on-Exchange) has wrestled with the
same field, and every one of them lands somewhere different. This doc
picks where Fulfilled lands. The PM filter is the usual one: do not
ship half-built UI, do not invent scope v1 can't carry, and do not let
the architecture doc's "DEV_AUTH_BYPASS" rider live past the moment a
real user opens the app on day one.

`specs/pm_decisions_flutter_ui.md` (Risk 2, the prior "remove the
'I already have an account' link" ruling — superseded by this doc),
`specs/flutter_ui_architecture.md` §4 (the `go_router` shape) and §8
(T-04, T-08, T-11, T-15), `specs/openapi.yaml` (`/health` exists,
`/auth/login` does not, bearer-only `securityScheme`), and
`specs/backend_tickets_ledger.md` (where BE-008 / BE-009 land if the
backend team agrees the API needs to grow) are the tiebreakers above
this doc. Where this doc decides something contradicting Risk 2 or the
architecture doc, the architect's implementation plan is the place
that resolves it — usually by amending the screen brief, not by
re-litigating the rule here.

Reading order for the architect:

- `specs/pm_decisions_flutter_ui.md` Risk 2 — the prior call that this
  doc reverses, with the original rationale intact.
- `specs/flutter_ui_architecture.md` §4 (routing), §5 (state — where
  `authTokenProvider` and the new `serverConfigProvider` live), §8
  (tenants the login screen inherits: T-04 accent, T-08 skeletons,
  T-11 inline errors, T-15 form-factor branches at the root, T-24
  post-mutation navigation).
- `specs/openapi.yaml` lines 67–89 (the `/health` endpoint we'll probe
  for URL validation) + the `bearerAuth` `securityScheme` at lines
  761–770 (the only auth shape the wire knows today).
- `specs/pm_ux_pack.md` §1–2 — closest analog for prose style and the
  accept / defer / reject discipline applied below.

---

## 1. Context

Fulfilled is **self-hostable** — each customer runs their own Rust
server against their own Postgres, on their own domain, with their
own TLS cert (or none). The user has now scoped the login surface
with one binding constraint: on **mobile**, the backend URL is
**dynamic per client** because each customer points their phone at
their own server; on **web**, the URL is **the page's own origin**
because the customer already typed it into the browser address bar.
v1 today ships against a compile-time `--dart-define=API_BASE_URL`
(documented in `client/lib/data/api_client.dart`), uses
`--dart-define=DEV_AUTH_TOKEN` for the bearer (defaults to
`dev-bypass` in debug per `client/lib/data/auth_token.dart`), and
explicitly hides the "I already have an account" link on onboarding
step 1 per Risk 2. The seam is partially built: `AuthTokenNotifier`
is a `Notifier` with `signIn(token)` / `signOut()` already wired (UX
pack QL-019); the `ApiClient`'s `baseUrl` is the only piece still
compile-time. This doc closes that gap and **reverses Risk 2**:
v1 ships a real login screen, the onboarding "I already have an
account" link returns, and the dev-bypass token survives only as the
debug-mode seed it has always been.

---

## 2. Competitive survey

Six apps surveyed end-to-end, three for one-line datapoints. The
columns are the ones that matter for **our** decision: where the URL
field lives, what HTTPS posture the app takes, what validation
timing looks like, how errors render, and whether multi-account is
in or out.

### Mastodon (iOS / Android — official apps)

The flagship "Choose your server" flow. Server selection is the
**very first screen** after splash, presented as a curated list of
servers maintained by the app (with custom-server entry tucked
beneath). Validation happens **on submit** — tap a server, the app
attempts an OAuth handshake, and the user lands on a webview if the
server is reachable. The whole flow is OAuth in a webview, which is
a different shape from what Fulfilled needs (single-server,
non-federated). Persistence is **per-account** (the app supports
multiple accounts on different servers natively, switchable from a
sidebar). The friction model is well-documented: users who don't see
their instance in the curated list often **give up before finding
the custom-server input**, and Mastodon iOS issue #886 has been open
asking for a "default server" feature for years. **Takeaway for us:**
a curated-server picker is the wrong shape because Fulfilled isn't
federated; one customer's server has nothing to do with another's.
We get the simpler version of this problem — one URL field, no list,
no discovery.
[Mastodon iOS issue #886](https://github.com/mastodon/mastodon-ios/issues/886),
[Mastodon servers directory](https://joinmastodon.org/servers),
[blog.joinmastodon.org official-apps](https://blog.joinmastodon.org/2022/04/official-apps-now-available-for-ios-and-android/).

### Bitwarden (iOS / Android)

The cleanest self-hosted-toggle shape we found. The login screen
shows a **"Logging in on" dropdown** at the top of the form; the
default is `bitwarden.com` (cloud) and the dropdown reveals a
**"Self-hosted"** option. Selecting it slides in a **Server URL**
field that the user fills with `https://my.bitwarden.example.com`.
**HTTPS is enforced** — addresses without `https://` produce an
explicit error message before submit; `http://` is rejected outright
in mobile. Multi-account is **supported on desktop** (each account
can be on a different server) but the mobile docs don't clarify
mobile multi-account. Validation timing isn't documented in the help
center but the field is a save-then-attempt shape (the form has a
discrete "Save" button on the self-hosted sheet, then the user
returns to the login screen and enters credentials). **Persistence**
is per-app — the URL survives across sessions until the user
explicitly changes it via the same dropdown. **Takeaway for us:**
the "default to cloud, opt into self-hosted via a dropdown" pattern
doesn't apply to Fulfilled (we have no cloud), but the **HTTPS-only
enforcement at the field level** is exactly the posture we want.
[Bitwarden — Connect Individual Clients](https://bitwarden.com/help/change-client-environment/),
[Bitwarden — Configure Clients Self-Host](https://bitwarden.com/help/configure-clients-selfhost/).

### NextCloud (iOS / Android)

The longest-established pattern in this space. First screen on a
fresh install is **only a server URL field** ("Server address" with
placeholder `https://cloud.example.com`). The mobile app then opens
a **webview against `<server>/index.php/login/flow`** (NextCloud's
Login Flow v2) which handles the username + password + 2FA inside
the server's own HTML, and on success the server redirects back to
the app via a `nc://login/server:…&user:…&password:…` deep link.
Validation timing is **on submit** with a server-side probe — if the
URL is reachable and serves NextCloud, the webview opens; if not,
the user sees a "Couldn't connect to server" error inline below the
field. Multi-account is **supported and prominent** — long-press on
the avatar in the file list shows the account switcher. Persistence
is per-account (each connected account stores its server URL +
session token in the device keychain). **Takeaway for us:** the
"URL first, credentials second" two-step flow is canonical and
proven, but it's two screens not one. Fulfilled's simpler
single-server model can collapse this to **one screen with three
fields** — URL, username, password — without losing clarity.
[NextCloud Login Flow docs](https://docs.nextcloud.com/server/latest/developer_manual/client_apis/LoginFlow/index.html).

### Element / Matrix (iOS / Android — Element X)

The most-criticised UX in this list, instructively. The login screen
defaults to **`matrix.org`** (the public homeserver) with a "Change
server" affordance. Tapping it reveals a homeserver URL input.
Validation is **on submit** — the app probes the homeserver's
well-known endpoint and the OIDC discovery URL, and errors land
inline. The well-documented friction: error messages like *"We
couldn't reach this homeserver"* are **vague**, the field is **picky
about trailing slashes and protocol prefixes** (older Element-web
issue #4505), and the suggested "contact your homeserver admin"
message is unhelpful when the homeserver admin **is the user**.
Multi-account is supported. Persistence per-account.
**Takeaway for us:** specific, actionable error messages matter
more than terse ones. *"Couldn't reach https://my.server:8080 —
check the address and your network"* beats *"Couldn't reach this
homeserver"* by a wide margin, and we should surface the **HTTP
status code** or the **specific failure reason** (DNS, TLS, 404 on
healthcheck) inline below the field, not in a separate dialog.
[Element X Android issue #4556](https://github.com/element-hq/element-x-android/issues/4556),
[Element Web issue #4505 (trailing slash)](https://github.com/element-hq/element-web/issues/4505),
[Element Web issue #15891 ("Sign into your homeserver" UI confusing)](https://github.com/vector-im/element-web/issues/15891).

### Plex (iOS / Android)

A different shape: Plex defaults to **cloud-mediated discovery** via
plex.tv (the user signs into plex.tv, and the app discovers their
home server through that account). The **manual server URL** path
exists but is buried — Roku and Android expose a "Manual Connection"
in settings, **IP address only** (not URLs), and community feature
requests for URL-instead-of-IP have been open for years. HTTPS is
not enforced in the manual path; users can wire local-network HTTP
explicitly. Multi-account: yes (Plex Home, plus multiple servers per
account). **Takeaway for us:** the discovery-via-cloud model
specifically does not apply to Fulfilled — there is no
`fulfilled.com`. The Plex manual-IP-only friction is the
anti-pattern we want to avoid: customers running behind reverse
proxies or with custom domains need to type a **URL**, not an IP.
[Plex Forum — Provide ability to specify URL instead of IP](https://forums.plex.tv/t/provide-the-ability-to-specify-a-url-instead-of-an-ip-address-for-manual-connections/906419),
[Plex Forum — Android app doesn't use custom access URLs](https://forums.plex.tv/t/plex-for-android-doesnt-use-servers-custom-access-urls/923682),
[Plex Support — Network](https://support.plex.tv/articles/200430283-network/).

### Outlook Mobile (iOS / Android — Exchange on-premise)

The "enterprise self-hosted" pattern. Outlook's onboarding tries
**autodiscovery** (DNS SRV records, well-known endpoints) and only
exposes a manual server URL field if autodiscovery fails or the user
toggles **"Advanced settings"** during setup. Manual fields include
server name, domain, port, and SSL toggle. HTTPS is the
out-of-the-box default; non-SSL is a checkbox-toggle within
advanced. Validation is **on submit** with an Exchange handshake.
Multi-account: yes, prominent (Outlook is multi-mailbox-first by
design). **Takeaway for us:** the advanced-settings pattern is
appropriate when **most users do not need to configure a server
URL** (the cloud-default case). Fulfilled inverts that — **every
mobile user needs the URL** — so hiding it behind "advanced" is the
wrong call. We expose it on the first screen.
[Microsoft — Set up email in Outlook for Android](https://support.microsoft.com/en-us/office/set-up-email-in-the-outlook-for-android-app-886db551-8dfa-4fd5-b835-f8e532091872),
[Microsoft Learn — Account setup with modern auth](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/outlook-for-ios-and-android/setup-with-modern-authentication).

### Jellyfin, Vaultwarden, Calibre-Web — one-line datapoints

- **Jellyfin (iOS / Android).** Server-first flow: "Add server" → URL
  field with placeholder `https://jellyfin.example.com:8096` → server
  probe → login form. URL must include the full path (including any
  reverse-proxy `/baseurl`). HTTPS not enforced. Multi-account
  (multi-server) supported via a server switcher. **Quick Connect** —
  short numeric code from an already-authenticated client — is an
  optional second auth shape. Same takeaway as NextCloud: URL first,
  credentials second; the field accepts full URLs including non-default
  ports.
  [Jellyfin — Quick Connect](https://jellyfin.org/docs/general/server/quick-connect/),
  [Jellyfin — Networking](https://jellyfin.org/docs/general/post-install/networking/).
- **Vaultwarden** (the Rust re-implementation of the Bitwarden server)
  uses the **official Bitwarden clients**, so the UX is Bitwarden's —
  the relevant constraint is just that mobile self-hosted users hit
  the same HTTPS-required, dropdown-tucked-on-the-login-screen flow.
  Notable for us: there's a long-standing community discussion about
  iOS clients having more trouble than Android with self-signed certs
  (Vaultwarden discussion #6086). **Takeaway:** "the cert chain has to
  validate" is a real customer pain point we should surface in errors,
  not hide.
  [Vaultwarden discussion #6086](https://github.com/dani-garcia/vaultwarden/discussions/6086).
- **Calibre-Web** is web-only (no native mobile app) — the URL is the
  browser address bar by definition, which is the same shape as
  Fulfilled's web tier. No datapoint to disagree with.

### Synthesis table

| App | URL field lives | Default | HTTPS | Validation | Errors | Persistence | Multi-account |
|---|---|---|---|---|---|---|---|
| Mastodon | First screen, in a curated list with custom-server tucked beneath | Curated list of public instances | Required | On submit (OAuth handshake) | Inline + webview fallback | Per-account (sidebar switcher) | Yes (native) |
| Bitwarden | Login screen, behind a "Logging in on" dropdown | `bitwarden.com` (cloud) | Required | On save then on credential submit | Inline field error | Per-app | Desktop yes, mobile unclear |
| NextCloud | First screen, **only** field | Empty (placeholder example URL) | Recommended, not enforced | On submit (server probe) | Inline below field | Per-account (avatar switcher) | Yes (prominent) |
| Element X | Login screen, behind "Change server" | `matrix.org` | Required | On submit (well-known probe) | Inline (criticised as vague) | Per-account | Yes |
| Plex | Settings (after cloud login) | None (manual fallback) | Optional | On save | Modal | Per-server | Yes (servers + accounts) |
| Outlook | Behind "Advanced settings" toggle | Autodiscovery | Default on, advanced-off available | On submit (handshake) | Inline + dialog | Per-account | Yes (prominent) |
| Jellyfin | First screen, **only** field | Empty (placeholder example) | Not enforced | On submit (server probe) | Inline below field | Per-server | Yes |

The **pattern that fits Fulfilled** is NextCloud / Jellyfin: a small
number of customers, one server per install, URL field on the first
screen with no curated default. The pattern that does **not** fit is
Mastodon (no federation, no curated list to maintain) or Outlook
(autodiscovery is overkill for a one-server-per-customer model).
Bitwarden's HTTPS-required posture is the policy we adopt; Element's
vague-error anti-pattern is the one we explicitly avoid.

---

## 3. UX best practices for self-hosted login

Pulled from the survey above, distilled into rules the architect can
hold the login screen to. Each is one sentence with one supporting
sentence.

1. **The URL field defaults to empty, not to a placeholder URL the
   user might accidentally submit.** Render the example as
   `helperText` *below* the field ("e.g. `https://fulfilled.mydomain.com`"),
   not as the field's `value` — accidentally submitting the placeholder
   is the #1 first-run failure mode in flows like Mastodon's that
   pre-fill anything.
2. **Validate on submit, not on blur or while typing.** Typos during
   typing should not surface errors; the user is mid-thought.
   On-submit validation hits the server with a real probe, and that's
   the moment the user has explicitly asked "is this address
   correct?".
3. **Probe a known endpoint to confirm reachability, not just URL
   syntax.** A URL that parses can still be wrong (DNS failure, wrong
   port, server not running) — a server probe surfaces those errors
   inline before the user types a password into a black hole.
4. **Surface specific failure reasons in the inline error, not a
   generic "Couldn't connect".** Distinguish DNS failure ("Couldn't
   find a server at that address"), TLS failure ("Server's certificate
   isn't valid"), HTTP error ("Server responded with 503 — it may be
   down"), and 404 on the healthcheck ("That address answered, but
   doesn't look like a Fulfilled server"). Element X's "we couldn't
   reach this homeserver" is the cautionary tale.
5. **Enforce HTTPS by default; allow HTTP only behind an "Advanced"
   disclosure with a copy-block warning.** Self-hosted users on local
   networks (`http://192.168.1.x`) are a real cohort; gating HTTP
   behind an explicit "I understand this is unencrypted" gesture keeps
   the default safe without alienating the LAN cohort.
6. **Persist the server URL across sign-out so re-login is fast.**
   When the user signs out they almost always sign back in to the
   same server; clearing the URL on sign-out turns the re-login flow
   into a re-discovery flow.
7. **Surface the server URL in the profile screen, read-only, so the
   user can see which server they're connected to.** This is the
   "which account am I on?" affordance the multi-account apps in the
   survey all have; in our single-server-per-account world it
   prevents the "why is my data different" support ticket.
8. **Allow trailing slashes, scheme-omitted ("mydomain.com"), and
   port-explicit ("mydomain.com:8443") inputs and normalize them
   silently.** Browser-style URL leniency matters because the user is
   typing a URL they know from the browser bar, not one they know from
   the Element-X-style spec page; rejecting `mydomain.com/` because
   it has a trailing slash is the wrong shape (Element web issue
   #4505 caught Matrix for exactly this).

---

## 4. User stories

Standard form. Six stories covering the first-run, web, server-switch,
typo, scheme-handling, and the persistence path.

**LOG-S1 — First-run mobile login (URL → username → password).**
*As a* customer who has just installed the Fulfilled mobile app on a
fresh device, *I want to* enter my server's URL, my username, and my
password on one screen, *so that* I can be signed in and on the Today
view within thirty seconds of opening the app.
**Acceptance:** the login screen renders three fields top-to-bottom
(URL, username, password) with an "Sign in" CTA at the bottom. On tap
the app probes `GET <url>/api/v1/health`, then posts credentials, then
navigates to `/today`. The whole flow is one screen.

**LOG-S2 — First-run web login (origin-implicit, two fields).**
*As a* customer who has just typed
`https://fulfilled.mydomain.com/login` into their desktop browser,
*I want to* see only a username and password field, *so that* I
don't have to re-type the URL I just typed into the address bar.
**Acceptance:** when running on web (`kIsWeb`), the login screen
does not render the URL field. The API base URL is read from
`Uri.base.origin` (the page's own origin) plus the `/api/v1`
suffix.

**LOG-S3 — Re-login after sign-out (URL persists).**
*As a* user who signed out from the Profile screen, *I want to*
return to the login screen with the server URL already filled
(possibly the username, never the password), *so that* the typical
re-login path is two field touches, not three.
**Acceptance:** after `signOut()` clears the bearer token, the
`auth_config` Hive box retains `base_url` and `last_username`.
The login screen reads both on mount and pre-fills the URL field
and the username field; the password field is empty and focused.

**LOG-S4 — Server switch (sign out, then sign in to a different
server).**
*As a* user who has moved their Fulfilled instance to a new domain
(or is signing in to a friend's instance for testing), *I want to*
sign out and change the server URL on the re-login, *so that* I
don't have to uninstall and reinstall the app.
**Acceptance:** the login screen's URL field is editable (not
read-only after a previous sign-in). On submitting a new URL, the
existing `auth_config.base_url` is overwritten and the outbox box
is cleared (because pending writes against the old server have no
meaning against the new one).

**LOG-S5 — Typo in the server URL surfaces inline, not as a dialog.**
*As a* user who fat-fingered `fullfilled.example.com` (two L's), *I
want to* see a clear inline error below the URL field naming what
failed, *so that* I know whether to fix the URL or fix my network.
**Acceptance:** on submit, if the URL doesn't resolve (DNS), doesn't
respond (timeout), responds with a TLS error, or responds with a
non-200 on the healthcheck, the error text appears under the URL
field in `AppColors.danger` with the specific reason ("Couldn't find
a server at that address" / "Server's certificate isn't trusted" /
"Couldn't reach the server (timed out)" / "That address answered, but
doesn't look like a Fulfilled server"). The username and password
fields keep their input intact.

**LOG-S6 — HTTP-bare URL is rejected with an actionable nudge.**
*As a* user who typed `192.168.1.50:8080` into the URL field
(no scheme), *I want to* see the app normalize that to
`https://192.168.1.50:8080` and try that first, then on TLS failure
prompt me to allow HTTP explicitly, *so that* the default-safe HTTPS
policy doesn't block my LAN-only home setup.
**Acceptance:** scheme-less input is upgraded to `https://` on submit.
On TLS handshake failure, the error message is "Couldn't establish a
secure connection. If this is a local server without HTTPS, you can
[allow plain HTTP for this address]." The bracketed text is a tappable
disclosure that toggles `http://` for the next submit; the toggle
state does not persist across app launches (re-confirmed every
session).

**LOG-S7 — Onboarding-to-login handoff (and back).**
*As a* user who taps "I already have an account" on onboarding step
1, *I want to* land on the login screen with the URL field empty and
ready, *so that* the onboarding flow doesn't trap me when I have an
existing account on an existing server. Conversely, from the login
screen tapping "Don't have an account? Sign up" returns me to
onboarding step 1.
**Acceptance:** step 1 of onboarding regains a secondary text link
("I already have an account") below the primary CTA. Tap →
`context.go('/login')`. The login screen renders a `TextButton`
labelled "Don't have an account? Sign up" below the "Sign in" CTA,
which `context.go('/onboarding/1')`s.

---

## 5. Decision: mobile login flow

The mobile login screen is the heart of this doc. Six decisions
below, each opinionated.

### 5.1 Where the URL field lives — **first screen, alongside username
and password**

Three fields top-to-bottom: **Server URL → Username → Password**.
Not three screens. Not a separate "advanced" disclosure. Not a
settings-only field that the user has to discover before they can
sign in.

**Rationale.** Every Fulfilled mobile user needs to provide a server
URL on first run — there is no cloud default to fall back to, no
discovery via plex.tv, no curated list. The "advanced disclosure"
shape (Outlook, Bitwarden's dropdown) is appropriate when *most*
users don't need the URL; that inverts here. The two-screen shape
(NextCloud, Jellyfin — URL first, then credentials) is reasonable
but adds a navigation step we don't need: Fulfilled doesn't do
OAuth-in-a-webview, it just POSTs a JSON body and gets a token back,
so all three inputs can live on one form. Keeping all three on one
screen also makes the "what changed?" mental model on re-login
straightforward: the user sees URL + username pre-filled and types
the password.

**Layout.** Compact: a `Column` inside a `ScrollView` with the logo
at top, a 24-pt headline "Sign in to your server", the three fields
stacked at standard spacing (`context.space.x4` between), the "Sign
in" primary button as a full-width `PrimaryButton`, and a "Don't
have an account? Sign up" `TextButton` below. The URL field has
`helperText: "e.g. https://fulfilled.mydomain.com"` rendered below
it in `context.text.meta` / `context.colors.ink3`.

**Tenancy compliance.** T-15 (form-factor branches at the root) —
the login screen file has a compact branch (single-column form
centred) and a web/expanded branch (centred card max-width 420) and
picks at the root. T-04 (accent only for primary actions) — only
the "Sign in" button is `AppColors.accent`; field focus rings can
use accent but field labels stay ink. T-11 (errors are inline) — all
error states are red help-text under the offending field, no
`AlertDialog`s.

### 5.2 URL validation — **on submit, against `GET /health`, 8s
timeout**

When the user taps "Sign in", the client:

1. Normalizes the URL: trim whitespace, strip trailing slashes,
   prepend `https://` if no scheme, append `/api/v1` as the API path
   suffix.
2. Fires `GET <normalized>/health` with an 8-second timeout
   (matches the `ApiClient`'s existing `connectTimeout` budget of
   10s — `/health` is a fast endpoint and 8s is generous).
3. On 2xx with `{ status: "ok" }`: proceeds to step 4 (credential
   POST).
4. Fires `POST <normalized>/auth/login` with `{ username, password }`
   (the new BE-008 endpoint — see §8).
5. On 200 with `{ token }`: writes `auth_config` to Hive
   (`base_url`, `last_username`), calls
   `authTokenProvider.notifier.signIn(token)`, then
   `context.go('/today')` per T-24 Case 2.
6. On non-2xx on either probe or login: surfaces an **inline error
   under the offending field** with the specific reason.

**Why `/health`, not `/openapi.yaml`.** `/health` is the
already-shipped, unauthenticated, deliberately-cheap liveness probe
(openapi.yaml lines 67–89). It returns a tiny JSON body (`{ status:
"ok" }`) on 200. Probing `/openapi.yaml` would work but it's a much
larger response and (depending on server config) may not be
unauthenticated. `/health` is the right probe.

**Why on-submit, not on-blur.** On-blur validation fires the moment
the URL field loses focus, which on mobile is the moment the user
taps the username field — surfacing an error before the user has
even finished entering credentials breaks their concentration and
trains them to ignore the error indicator. On-submit validation is
the moment the user has explicitly asked the app "go check this".

**Why 8 seconds.** Long enough to cover a slow first-cellular DNS
resolution + a server cold-start; short enough that the user
doesn't sit on a spinning button. The error text on timeout is
"Couldn't reach the server (timed out after 8 seconds). Check the
address and your network."

**Skeleton, not spinner (T-08).** While the request is in flight,
the "Sign in" button transitions to a disabled state showing a
**skeleton** sized to the button's text width (per T-08 — never a
centered `CircularProgressIndicator`). The other two fields go
read-only-but-not-disabled (the cursor blinks, the value is
visible, edits are no-ops).

### 5.3 HTTPS policy — **default HTTPS; HTTP allowed only after
explicit per-session toggle on TLS failure**

The default attempt is always HTTPS. If the user types `myserver.com`,
the client tries `https://myserver.com`. If the user types
`http://myserver.com` explicitly, the client **rejects it** on the
first submit with the message *"For your security, Fulfilled connects
over HTTPS by default. If you really need plain HTTP, tap [allow
HTTP for this address]."*. The disclosure-tap toggles an in-memory
flag for the next submit only; the flag does not persist to Hive.

**Why not just allow HTTP always.** Self-hosted users on LAN are
real, but **most** self-hosted users run a reverse proxy with a
free Let's Encrypt cert. Defaulting to HTTPS forces the right
posture by default and only adds friction for the LAN-only minority
— who get a single tap to opt in, every session. The "every session"
re-confirm is deliberate: it prevents the user from forgetting that
their traffic is unencrypted.

**Why a per-session toggle, not a persistent setting.** A persistent
"allow HTTP" toggle would be the kind of setting that's easy to
forget existed; surfacing the prompt on every cold-launch login keeps
the user aware of the trade-off. If the user signs in successfully
once over HTTP, the URL persists with its `http://` scheme in
`auth_config`; on subsequent re-logins the app re-uses the scheme
without re-prompting (the re-prompt is only for the first-time
HTTP login).

### 5.4 Default / placeholder — **empty by default; helper text
below the field**

The URL field's `controller` is empty on first mount (for a brand-new
install). The placeholder pattern (a greyed-out URL string inside the
field) is **rejected** — Mastodon's curated-list-with-defaults UX is
specifically called out as a friction source in this doc's §2, and
the equivalent on a single-field form is a placeholder URL the user
might accidentally submit by tapping "Sign in" without typing.

Instead, the field uses Material's `helperText` slot to render the
example **below** the field in `context.text.meta` /
`context.colors.ink3`: *"e.g. https://fulfilled.mydomain.com"*. The
helper text replaces with the inline error on submit failure.

### 5.5 Persistence — **`auth_config` Hive box, survives sign-out**

A new Hive box `auth_config` opens at app boot (alongside the
existing `outbox_log` box in `main.dart`). Schema:

```
auth_config: Box<String>
  - base_url: String?      // e.g. "https://fulfilled.mydomain.com"
  - last_username: String? // last successful sign-in's username
```

The bearer token is **not** stored in the Hive box — it lives only
in `authTokenProvider`'s in-memory state, seeded on app launch from
flutter_secure_storage (iOS Keychain / Android EncryptedSharedPrefs).
Rationale: Hive is local plaintext; tokens belong in the platform
keystore. The base URL is not secret; Hive is fine.

**Architect's call to make.** The exact secure-storage package
(`flutter_secure_storage` vs `flutter_keychain` vs a thin wrapper)
is an implementation detail; what's binding is **the bearer token
goes to platform secure storage, the server URL goes to Hive,
neither is `--dart-define`d anymore in release builds**.

**Sign-out behaviour.** `signOut()` already clears the in-memory
token and the outbox. We extend it to clear the secure-storage
token but **not** the `auth_config` box — the URL and the last
username survive. The next call to the login screen reads them and
pre-fills.

### 5.6 Multi-account — **not in scope for v1**

v1 is single-server, single-user. The `auth_config` box stores one
URL, one username; the bearer token is one slot. Switching accounts
means signing out and signing back in.

**Rationale.** Multi-account is a real product surface (account
switcher chrome on the profile screen, per-account data isolation
on every Hive box, per-account outbox state, account-switcher in the
top bar or sidebar) that touches half the app. It is **v1.1 work at
the earliest**, and only if customer demand surfaces. The
single-server model is the right v1 simplification — most customers
have one Fulfilled server.

---

## 6. Decision: web login flow

### 6.1 API base URL — **`Uri.base.origin + "/api/v1"`**

On web (`kIsWeb`), the API base URL is **read from the page's
origin**, not from a custom server field. The customer has already
typed `https://fulfilled.mydomain.com/login` into their browser
address bar; there's no second URL to provide.

Implementation: the `apiClientProvider` gets a small kIsWeb branch
that reads `Uri.base.origin + '/api/v1'` instead of the Hive-backed
`auth_config.base_url`. The `--dart-define=API_BASE_URL` mechanism
stays as the **dev-mode override** for `flutter run -d chrome`
against a local Rust server (since `Uri.base.origin` would be
`http://localhost:port` of the Flutter dev server, not the Rust
server's port).

### 6.2 Login screen — **two fields, no URL field**

The web login screen renders only **Username → Password → Sign in**.
The URL field is conditionally hidden (`if (!kIsWeb)` at the field
slot). Everything else — the inline error UX, the "Don't have an
account? Sign up" link, the post-login redirect to `/today` — is
identical to mobile.

### 6.3 Detection seam — **`apiClient` reads from a single
`serverConfigProvider`**

To keep the seam clean: a new provider `serverConfigProvider`
returns a `ServerConfig { baseUrl: String }` with platform-specific
construction:

- **Web:** reads `Uri.base.origin + '/api/v1'`, ignores Hive
  entirely.
- **Mobile:** reads `auth_config.base_url` from Hive, falls back to
  `null` (which the router uses to gate the login screen — see §7).

The `apiClientProvider` reads `serverConfigProvider` and uses its
`baseUrl`; nothing else in the app depends on the platform branch.
This keeps T-15 honest: the platform branch happens at the
`serverConfigProvider` root, not sprinkled through repositories.

---

## 7. Decision: where the login screen lives in the app structure

### 7.1 Route — **`/login`, outside the `ShellRoute`**

The login screen has no nav chrome (no bottom tabs on mobile, no
sidebar on web). It is a full-page context like `/onboarding/:step`
or `/foods/:foodId`. The route registration goes in
`lib/routing/app_router.dart` outside the `ShellRoute` block,
alongside `/onboarding/:step`.

```
GoRoute(
  name: Routes.loginName,    // 'login'
  path: Routes.loginPath,    // '/login'
  builder: (_, __) => const LoginScreen(),
),
```

### 7.2 Bootstrap gating — **token presence drives initial route**

Today the router's `initialLocation` is `/today` and the app crashes
into the day view regardless of auth state (the dev-bypass token
masks this). The new behaviour:

- On boot, the app reads the bearer token from secure storage into
  `authTokenProvider`.
- The router's `redirect` function checks `authTokenProvider`:
  - **token present:** allow the requested route (default `/today`).
  - **token null, route ≠ `/login`/`/onboarding/*`:** redirect to
    `/login`.
  - **token null, route = `/login` or `/onboarding/*`:** allow.

This is a standard `go_router` redirect. Onboarding remains
reachable without a token because onboarding is the **new-user
setup flow** — its end state is signing in with a freshly-created
account. (For v1 we assume the user creates the account on the
server out-of-band; "Sign up" is in §9's anti-recommendations.)

### 7.3 Re-add "I already have an account" on onboarding step 1 —
**this reverses PM Risk 2**

Onboarding step 1 regains a secondary affordance below the primary
CTA: a `TextButton` labelled **"I already have an account"** that
`context.go('/login')`s. This **reverses the PM Risk 2 ruling in
`pm_decisions_flutter_ui.md`**, which removed the link because v1
ran against `DEV_AUTH_BYPASS` and had no login screen for the link
to land on. That premise is now obsolete: this doc ships the login
screen, so the link has a destination.

**Architect: amend `pm_decisions_flutter_ui.md` Risk 2 in the same
change that ships the implementation.** Add a `> **Addendum
2026-05-16 — login flow shipped.** The "remove the link entirely"
decision is superseded by `specs/pm_login.md`. The link is back; it
routes to `/login`.` block at the bottom of the Risk 2 section,
preserving the original rationale.

**Implementation in `step_1_welcome.dart`.** The widget gains a
`TextButton` rendered below the existing feature list (or below
the `OnboardingStepShell`'s footer CTA — architect's discretion;
the simpler placement is in the welcome body widget itself, since
that's where the link was originally before Risk 2 cut it).

### 7.4 "Don't have an account? Sign up" on `/login`

Below the "Sign in" button on the login screen, a `TextButton`
labelled **"Don't have an account? Sign up"** routes to
`/onboarding/1`. Symmetric to §7.3 in both placement and shape.

---

## 8. Backend implications

Two backend tickets flagged for the canonical ledger
(`specs/backend_tickets_ledger.md`). Both are **proposals to the
backend team, not unilateral demands** — the architecture-doc Note
that this PM doc doesn't ship backend code stands.

### BE-008 — Canonical login endpoint `POST /auth/login`

**Status:** pending (proposed by this doc).
**Goal:** add `POST /auth/login` that takes
`{ username: string, password: string }` and returns
`{ token: string, expires_at?: string }` on success, or `401` with
the standard `Error` body on credential failure.

**Why it's needed.** The current `openapi.yaml` declares
`bearerAuth` as the only `securityScheme` (lines 761–770) and
explicitly notes that v1 ships against `DEV_AUTH_BYPASS` with JWTs
expected in production "validated against a JWKS endpoint." There
is **no endpoint that issues a token** — production deployments
today would require the operator to mint a JWT out-of-band and
paste it into the app, which is not a v1 customer experience.
`POST /auth/login` is the canonical "trade username+password for a
bearer token" surface.

**Open question for the backend team.** Does login validate against
a JWKS-backed external IdP (in which case `/auth/login` is a
pass-through to that IdP) or does Fulfilled grow a local-credential
store (in which case `users` gains a `password_hash` column with a
canonical hash algorithm — argon2id is the modern default)? This
PM doc does not pick one; the backend team's design choice
determines the shape. The **client behaviour is the same** either
way (POST username+password, receive a token), so the BE-008 wire
shape above stands independent of the implementation choice.

**Client workaround until BE-008 lands.** The login screen can ship
**ahead of BE-008** by treating `password` as the literal bearer
token — the user pastes their JWT into the password field, and the
client `signIn`s with it directly. This is an acceptable
operator-led path for v1.0 if BE-008 doesn't make the cut; the
client surface (URL + username + password fields) is unchanged
between this workaround and the BE-008-shipped flow. Document the
workaround in the login screen's dartdoc with a `// TODO BE-008`
marker.

**Open question on token lifetime.** v1 ships **no refresh token**
— the bearer is the only credential, and on `401` from any endpoint
the client signs the user out and routes to `/login`. Refresh-token
support is v1.1+ work (BE-008-refresh, not flagged here). The
`expires_at` field above is **optional in the response**; if absent
the client treats the token as "valid until 401".

### BE-009 — `/health` clarification + CORS confirmation

**Status:** pending (proposed by this doc).
**Goal:** confirm `/health` is reachable **before** the `/api/v1`
prefix (per `openapi.yaml` lines 14–15 the `/api/v1` prefix only
applies inside that document's path-prefix scope, but
operationally `/health` on most Rust servers lives at the root,
not under `/api/v1`). Confirm CORS allows the login probe from
arbitrary origins so the web tier can do the same probe.

**Why it's needed.** This is half a documentation ticket and half a
"please verify the actual wired path matches my reading of the
spec." The client's URL-validation probe wants to hit
`<base>/health` (or `<base>/api/v1/health`, depending on the
backend's mount point); we need one canonical answer. The architect
should treat this as **blocking-on-clarification, not blocking-on-
implementation** — the path is one line of code on the client side
once the answer is in.

**Open question.** Is `/health` mounted at the server root or under
`/api/v1`? `openapi.yaml` reads both ways depending on how strictly
the "All paths are served under the `/api/v1` prefix" sentence
applies; the spec's own example server URL
(`https://{host}/api/v1`) suggests `/api/v1`-rooted, in which case
the client probes `<base>/api/v1/health`.

### Existing `bearerAuth` posture — **unchanged**

This doc does **not** change the `bearerAuth` `securityScheme`. All
authenticated endpoints continue to expect `Authorization: Bearer
<token>` exactly as today. The only new surface is `POST /auth/login`
(BE-008), which itself is `security: []` (un-credentialed — it's
the credential exchange).

---

## 9. Anti-recommendations / out-of-scope

Be explicit. The following are **not** in v1's login surface.

1. **No social login.** No "Sign in with Google", "Sign in with
   Apple", or email-magic-link option. Each of those is real
   backend scope (OAuth client registration, callback URLs, identity
   linking) and a real per-customer-deployment configuration
   surface (each self-hosted instance would need its own OAuth
   client IDs). v2 work at the earliest, and only if customer
   demand surfaces; the canonical username+password path covers
   the user story without it.
2. **No multi-account / account switcher.** v1 is one account at a
   time. Per §5.6 above.
3. **No biometric unlock.** Face ID / fingerprint to unlock a
   cached session is a real polish item but it touches the
   secure-storage seam (the bearer would need to be encrypted at
   rest with a biometric-protected key) and the iOS / Android
   platform-channel surface; v1.1+.
4. **No "Stay signed in" toggle.** The default is **stay signed in
   until explicit sign-out**. A toggle would either be a no-op
   (the default is already "stay") or imply an auto-sign-out on
   app background which we are not building. The toggle is
   ceremonial and we don't ship ceremonial UI.
5. **No mDNS / Bonjour server discovery.** "Find Fulfilled servers
   on your local network" is a real feature for the LAN-only
   cohort but it's platform-channel work, requires user-facing
   permission prompts on iOS 14+, and the user already knows their
   server's address (they typed it in elsewhere already). v2+.
6. **No QR-code-based server URL hand-off.** Mastodon-adjacent
   pattern; nice for "I just set up the server, scan this code on
   your phone" but it's another surface area and the user typing
   `myserver.com` into a field works.
7. **No password reset flow.** Password reset is a backend-driven
   surface (email-based reset token, web page to consume the token)
   and v1 doesn't have email infrastructure. v1.1+ if BE-008 lands
   on a local-credential store; never (defer-to-IdP) if BE-008 is
   an IdP pass-through.
8. **No "remember device" / "trust this device" semantics.** A
   bearer-token-survives-app-close world is the entire trust model.
   Per-device trust scoring is over-scope.
9. **No 2FA / TOTP / WebAuthn surface in v1.** A second factor is
   real product scope; if BE-008 lands a local-credential store, 2FA
   is the next ticket. Out of v1.
10. **No "switch server" in-app affordance separate from sign-out.**
    The pattern is "sign out → re-enter URL on the login screen" per
    LOG-S4. We are **not** building a "change server" entry in the
    profile screen that bypasses sign-out; the sign-out is the right
    safety gate (it clears the outbox, clears the secure-storage
    token, gives the user a chance to back out).
11. **No federated identity / cross-server auth.** Fulfilled is one
    server, one DB, per the user's brief. No bridging tokens between
    instances.

---

## 10. Punt list

Considered and explicitly deferred, with one-line rationale each:

- **Account switcher chrome on the profile screen.** v1.1 — depends
  on multi-account (§5.6 deferred); not load-bearing for v1.
- **"Servers" sub-screen in profile showing all connected
  servers.** v1.1 — same as above.
- **Sign-up form** (POST to a `/auth/register` endpoint). v1.1+ —
  operators create accounts out-of-band for v1 (the architect's
  call: maybe via a CLI command on the Rust server). The "Sign up"
  link on `/login` routes to onboarding step 1, which today is the
  setup flow; whether it terminates in a real account creation or a
  "contact your server admin" surface is BE-008-pack work.
- **Refresh-token rotation.** v1.1+ — bearer-only for v1; 401
  signs out and re-prompts. The architect should add a single
  Dio interceptor branch for this (already half-there at the
  401 site).
- **Forgot-password flow.** v1.1+ — see §9.
- **HTTP-allow as a persistent profile setting.** v1.1 — per
  §5.3 the toggle is per-session for v1; if customer feedback
  shows the per-session re-confirm is friction for LAN users, we
  promote it to a persistent setting then.
- **Configurable healthcheck endpoint.** Some self-hosted apps
  expose configurable validation probes (Element's `.well-known`
  pattern). Not relevant for Fulfilled — every Fulfilled server
  serves `/health` by definition (it's in our spec).
- **Server-discovery via `.well-known/fulfilled-server` JSON.**
  v2 — would unlock the "type your email address, app discovers
  the server" pattern via DNS, but requires email-as-identifier
  which we don't have.
- **Pre-configured server URL via MDM** (Bitwarden's "Server URL
  configured by enterprise policy"). v2 — interesting for the
  enterprise-deployment cohort that doesn't exist yet.
- **Allowlist of trusted server cert pins for HTTPS.** v2 — the
  default TLS posture (system root CA) is correct for the bulk of
  self-hosted users with Let's Encrypt certs; certificate pinning
  is over-scope for v1.
- **In-app log of recent server URLs** (history of
  previously-signed-in URLs, so the user can pick from a list).
  v1.1 — `auth_config` stores one URL today; promoting to a list
  is the multi-account adjacency (§5.6) and waits for that pack.
- **Server name / display name** (the user labels their server
  "Home" vs "Work"). v1.1 — same adjacency as the above.
- **Profile screen "Connected to ${server_url}" affordance.**
  Per §3 best-practice #7. **Architect: include this in the same
  ticket as the login screen** — it's a one-line addition to the
  existing profile screen ("Server: ${auth_config.base_url}" in the
  info card) and shipping it alongside the login screen prevents the
  "which server am I on?" support question on day one. Not deferred,
  actually — calling it out here as the smallest possible scope
  extension of this pack.
- **Theme/branding the login screen** (custom logo from a `/branding`
  endpoint on the server). v2+ — Fulfilled is self-hosted, customer
  may want their company's logo on the login screen. Nice but
  out-of-scope.

---

## 11. Sequencing recommendation

The architect will refine, but the PM-level ordering matters because
some pieces unlock others:

1. **BE-008 confirmation from the backend team.** Block on this for
   one read — the client UX is the same either way, but the
   architect needs to know whether v1.0 ships the "paste your JWT
   into the password field" workaround or the real `POST /auth/login`
   flow. **One asynchronous email's worth of unblock**; not weeks.
2. **`serverConfigProvider` + Hive box plumbing.** The platform
   branch (web reads `Uri.base`, mobile reads Hive) lands first; the
   `apiClientProvider` switches to read it instead of the
   `--dart-define`. This change is invisible to the user (the dev
   experience is unchanged because `--dart-define` survives as the
   dev override).
3. **`AuthTokenNotifier` reads from secure storage on app boot.**
   The existing `Notifier` gains an async-init shape: `build()`
   returns `null` initially, then a side effect (overrideWith in
   `main.dart` after the secure-storage read) seeds the token. The
   architect picks the exact shape — likely an async provider that
   the router waits on.
4. **`go_router` redirect gating on `authTokenProvider`.** The router
   gains a `redirect` function. `initialLocation` stays `/today`;
   the redirect handles the "no token → /login" branch.
5. **`/login` route + `LoginScreen` widget.** The screen ships
   against the BE-008 endpoint (or the "paste your JWT as the
   password" workaround if BE-008 hasn't landed).
6. **Onboarding step 1 regains the "I already have an account"
   link.** One-line change to `step_1_welcome.dart` + amendment to
   `pm_decisions_flutter_ui.md` Risk 2.
7. **Sign-out clears secure-storage token + outbox; preserves
   `auth_config`.** Extends the existing `signOut()` notifier method.
8. **Profile screen renders the connected server URL read-only.**
   The smallest §10-punt-list-promotion that ships in this pack.

Critical path is **BE-008 confirmation → `serverConfigProvider` →
`/login` route → onboarding link**; the secure-storage and the
profile-screen surface are smaller items that can land alongside.

---

## 12. Acceptance for the entire pack

"The login pack is shipped" means:

- A `/login` route exists in `app_router.dart`, outside the
  `ShellRoute`. It renders a `LoginScreen` with the three fields
  on mobile, two fields on web.
- `serverConfigProvider` is the only place the API base URL is
  read from; `apiClientProvider` reads it; the
  `--dart-define=API_BASE_URL` mechanism survives only as the dev
  override for `flutter run -d chrome` against `localhost`.
- `auth_config` Hive box opens in `main.dart` alongside
  `outbox_log`; the box survives sign-out.
- Bearer tokens are stored in platform secure storage
  (architect picks the package). `AuthTokenNotifier` reads on
  boot and writes on `signIn`.
- The router gates routing on `authTokenProvider`: no token →
  redirect to `/login` (except `/onboarding/*`).
- Onboarding step 1 has a "I already have an account" `TextButton`
  that routes to `/login`. `pm_decisions_flutter_ui.md` Risk 2 is
  amended with an addendum noting the reversal.
- The login screen validates the URL on submit via
  `GET <base>/health` (or `<base>/api/v1/health` pending BE-009
  clarification) with an 8-second timeout. Errors surface inline
  per the four classes in §3 rule 4.
- HTTPS is the default scheme on bare-domain input; explicit
  `http://` is rejected with a per-session "allow HTTP" disclosure.
- The profile screen renders a read-only "Server:
  ${auth_config.base_url}" row in the info card.
- The "I already have an account" link is symmetric: login screen
  shows "Don't have an account? Sign up" routing to `/onboarding/1`.
- Verification commands:
  - `flutter test test/features/login/login_screen_compact_test.dart`
  - `flutter test test/features/login/login_screen_web_test.dart`
  - `flutter test test/features/login/login_url_validation_test.dart`
  - `flutter test test/routing/auth_redirect_test.dart`
  - `flutter test test/data/auth_config_box_test.dart`
  - `flutter test test/data/server_config_provider_test.dart`
  - `flutter test test/features/onboarding/step_1_welcome_link_test.dart`
  - `grep -rn 'dart-define.*API_BASE_URL' lib/` → only one hit
    (the dev-override branch in `serverConfigProvider`).
- The architect produces `architect_login.md` mapping each of
  the pack's items to a developer-pickable ticket
  (LOG-001..LOG-NNN) with the file list per item; backend tickets
  BE-008 and BE-009 are added to `backend_tickets_ledger.md` in
  the same change.

The bar for this pack: a customer who runs `docker run fulfilled-server`
on `https://fulfilled.mydomain.com`, downloads the Flutter app on
their phone, opens it, sees a clean three-field form, types in
their URL, username, and password, and is on the Today view in
under thirty seconds — without any compile-time flags, without any
pasted JWTs, without any "sorry the URL isn't right" friction that
doesn't tell them *which* URL part is wrong. That's the self-hosted
login experience. Everything in this doc serves that thirty seconds.
