# Fulfilled — Product Audit & Opportunity Backlog

Author: PM
Date: 2026-05-17
Scope: Live app (`app.coolify.stolworthy.co`), API (`api.coolify.stolworthy.co`), monorepo at `/workplace/fulfilled/`. Driven via Playwright on desktop + iPhone 13 plus direct API probing as `dev`.

---

## Executive summary

- **The daily loop is broken at the most visible step.** Server emits per-serving kcal under `default_serving.kcal`; the FE looks for top-level `calories_per_serving`. Every search row therefore renders `—` for calories. This single contract drift breaks the moment-of-decision in every search.
- **Search ranking is unusable for common queries.** "apple" returns eight Apple Pies before a single fruit. "banana" returns Banana Chips. "egg" returns Egg Nog. The `quality_score` and `source` columns sit unused as ranking signals.
- **New users never reach the onboarding flow.** `/onboarding/*` exists and works, but the router doesn't gate fresh sign-ins into it. First-run users see a dashboard of dashes and discover `/me` and `/goals/new` themselves — or churn.
- **Two destinations are functionally broken.** Creating a custom food (`/foods/new`) crashes into a raw `DioException: 400` because go_router matches `/foods/:foodId` first. The only path to add a custom food doesn't work.
- **The catalogue is shallow and unlabelled.** 23.5K of OFF's 4.48M rows ingested; USDA servings are labelled `94.7 g` instead of "1 drumstick"; OFF categories collapse to `["en:undefined"]`.
- **The app is a logger, not a coach.** No weekly summary, no trend forecast, no streak, no goal-arrival projection, no "you under-shot protein 5 days running." Cronometer and MacroFactor have made coaching table stakes.
- **Engagement scaffolding is absent.** Zero notifications, widgets, watch app, share extension, email digest, friend graph, photos, or journaling. The product has no mechanism to bring the user back tomorrow.

**Sequencing:** unbreak the daily loop (search row kcal, search ranker, custom-food creation, onboarding gate, error surfaces) before anything else; then catalogue depth + serving labels; then the first coaching surface (weekly summary or trend insight). The worst outcome of next planning is to skip the unbreak list and ship a recipe builder on top of a search that returns Apple Pie for "apple."

---

## 1. Activation & onboarding

### 1.1 New users never reach the onboarding flow
**Why it matters.** A user signs in via OIDC, lands on `/today`, sees a flat ring with "Goal —", three macro bars with no fill, and no obvious "set me up" target. The 3-step onboarding flow (sex / birth / height / activity / goal) exists and is well-built — it just never auto-routes.
**Current state.** `app_router.dart` allows `/onboarding/*` un-authed but never *routes* an authenticated user with `sex == null` to it. `GET /me` carries the exact null signals to detect this.
**Suggested direction.** When an authenticated user lands and `sex || birth_date || height_cm || activity_level` is null, route to `/onboarding/1`. End onboarding with their first goal already saved so Today's ring has something to chase.
**Size:** S. **Priority:** must-fix gap.

### 1.2 First-run users see a "dashboard with dashes"
**Why it matters.** The Today screen always renders meal cards + ring + macro bars, even when the user has zero log entries lifetime. Empty meal cards, "0 kcal" ring, "Goal —" / "Burned —", every macro at 0g, the 7-day pill suppressed. Technically correct, emotionally hostile.
**Current state.** Today always renders the canonical layout.
**Suggested direction.** When the user has 0 log entries lifetime and no goal, replace the Today body with a "Let's log your first meal" panel: focused search, three example chips (breakfast yogurt / lunch sandwich / dinner chicken). The full Today view appears when the first entry saves.
**Size:** S. **Priority:** must-fix gap.

### 1.3 No sign-up path on the login screen
**Why it matters.** Mobile sign-in redirects to Authentik with "Don't have an account? Sign up" — but Authentik is gated and self-hosted. A consumer-positioned product needs either a real sign-up flow or honest copy about being invite-only.
**Current state.** Sign-up link is decorative; no provisioning.
**Suggested direction.** Decide whether Fulfilled is multi-tenant SaaS or single-tenant self-hosted, then either ship a local-credentials sign-up endpoint behind a flag, or replace the link with "Fulfilled is currently invite-only — request access at hello@…".
**Size:** M. **Priority:** high-leverage add (gates organic growth).

### 1.4 Time-to-first-logged-meal is one screen too many
**Why it matters.** From "I want to log a banana" the user does: Today → tap search → type → tap result → food detail → tap "Add to log" → wait for sheet → pick meal/quantity/unit → save. Six taps. Lose It! and MyFitnessPal compress this to three by allowing in-line logging from the result row.
**Current state.** Search → detail → sheet is mandatory even for foods with one default serving.
**Suggested direction.** Add a "+ Log default serving to {meal}" action on each search result row. Resolves the meal from time-of-day. Snackbar with "Edit" affordance for the 10% non-default case. Detail page stays available via name-tap.
**Size:** M. **Priority:** high-leverage add.

---

## 2. Core daily loop

### 2.1 Search rows show "—" instead of kcal (P0 bug)
**Why it matters.** This is the worst kind of bug — silent, visible, undermines trust at the decision moment. Users can't rank options without tapping each. Across desktop + mobile every row in every search renders an em-dash.
**Current state.** `loseit-api/src/routes/foods.rs::FoodSearchHitResponse` omits `calories_per_serving`. The OpenAPI spec and FE decoder (`food_repository.dart::_hitToFood`) both expect it. The kcal is present inside `default_serving.kcal`; the FE only synthesizes a serving when the *top-level* field is non-null.
**Suggested direction.** Add `calories_per_serving` to the API response (mirroring `default_serving.kcal`) *or* teach the FE to fall back to `default_serving.kcal`. Either unblocks every search interaction.
**Size:** S. **Priority:** must-fix gap.

### 2.2 Search ranking returns Banana Chips for "banana"
**Why it matters.** "apple" → 8 Apple Pies. "banana" → 5 Banana Chips/Sauces, no banana. "egg" → 5 Egg Nogs, no egg. "milk" → 5 brand-anonymous "Milk" rows. This is the moment the user decides whether Fulfilled is competent.
**Current state.** Ranking is trigram-order with no quality bias. `foods.quality_score` (0–100), `foods.nutriscore_grade`, and `foods.source` are populated and unused as ranking signals.
**Suggested direction.** Three-step ranker. (1) Boost exact-name and word-boundary matches above substring. (2) Generic/USDA-Foundation outranks branded variants for short queries. (3) `quality_score` and `nutriscore_grade` as tiebreakers. Server-side change in `loseit-core/src/service/food.rs`; data is already there.
**Size:** M. **Priority:** must-fix gap.

### 2.3 Today's ring is shapeless without a goal
**Why it matters.** Today shows a circle labelled "90 EATEN" with no fill, no remaining indicator, and the title "Today vs goal" when no goal exists. The card pretends to be informative.
**Current state.** `RingSummaryCard` renders regardless of goal state.
**Suggested direction.** When no active goal, change the title to "Today" and replace the ring with a "Set a daily target" CTA + macro bars (which still carry information). Reserve the ring for the state where it can fill.
**Size:** S. **Priority:** high-leverage add.

### 2.4 Logging the same breakfast twice in a row is the long way around
**Why it matters.** A logger should remember what you did. Today the same Tuesday breakfast as Monday requires the full search-tap-sheet path. Recent/Frequent chips help with the food but not the quantity-meal-unit combo. Lose It! offers "repeat yesterday's breakfast" as one tap.
**Current state.** `POST /log/copy` exists; the FE exposes it via the meal `...` menu as "copy from another day," not "repeat yesterday."
**Suggested direction.** Add a "Repeat yesterday's {meal}" row to each empty meal card. Single tap, snackbar undo. Reuses the existing endpoint with `from_date = yesterday, meal = X`.
**Size:** S. **Priority:** high-leverage add.

### 2.5 Quick Add is hidden behind a 24px lightning bolt
**Why it matters.** Quick Add (raw kcal without a food) is the "I'm at a restaurant, I'll estimate" keystone. Today it lives behind a thin icon next to the search field. The endpoint and sheet are built; discovery is invisible.
**Suggested direction.** Surface "Quick add kcal" as a named secondary action on each empty meal card and as a chip in the search empty state ("Don't see it? Add as Quick Add").
**Size:** S. **Priority:** high-leverage add.

---

## 3. Data quality & completeness

### 3.1 OFF ingest is at 0.5% — and the missing 99.5% is the long tail of brands users actually scan
**Why it matters.** A user scans a real shelf product; their barcode isn't in our 23.5K-row slice. They get a 404 → "Add as custom food" form (which currently crashes — see §7.1). For barcode lookups this is a soul-crushing failure mode.
**Current state.** 23,568 OFF rows out of 4.48M total; ingest binary crashes partway through (per `OVERNIGHT_REPORT.md`).
**Suggested direction.** Two tracks. Short-term: stabilize the ingest binary, even at 48h of wall-clock to backfill. Long-term: on 404 from `/foods/barcode/...`, proxy a live OpenFoodFacts API call before falling back to manual entry; persist the row on success so the next user hits cache. Turns a dead end into a fill-the-gap loop.
**Size:** M (ingest fix) / L (live proxy). **Priority:** must-fix gap.

### 3.2 USDA servings are labelled by raw grams, not human portions
**Why it matters.** USDA "Chicken, drumstick, meat only, cooked, braised" has three servings: 94.7 g, 114 g, 104 g. To a user these are unintelligible — they map to "1 drumstick" / "1 cup chopped" / "1 large drumstick" in the FDC source. Logging a drumstick requires converting "I ate one" → "approximately 95 grams."
**Current state.** USDA `servings.label = null` because ingest doesn't write the FDC `portion_description`.
**Suggested direction.** Update USDA ingest to write the FDC portion description into `servings.label`. Re-run for the 292 rows. Single data fix, disproportionate UX payoff.
**Size:** S. **Priority:** must-fix gap.

### 3.3 OFF categories collapse to `["en:undefined"]` and portion text is dropped
**Why it matters.** OFF ships rich category trees ("desserts > pies > apple-pies") and packaging serving sizes ("1 slice (1/8 pie)"). We discard both during ingest. Apple Pie comes back with a single 100g serving and a stub category — even though the source has "1 slice (105g)" right there.
**Suggested direction.** Two passes on OFF ingest: preserve the full category chain (powers future browse-by-category + similar-foods); parse `serving_size` text into real labelled servings when present. Compounds with §3.2 to make every food-detail page useful, not just custom ones.
**Size:** M. **Priority:** must-fix gap.

### 3.4 No recipe / meal builder — composite foods don't compose
**Why it matters.** "My breakfast" is yogurt + granola + blueberries + honey. Today the user logs four entries or creates a custom food with manually-merged nutrition. Every serious tracker has a recipe builder.
**Current state.** Custom foods are flat — `FoodCreate` takes servings, not constituent foods.
**Suggested direction.** Add a "Recipe" custom food kind: servings computed from a `(food_id, quantity, serving_id)` constituent list. Reuse the food+serving schema; constituents live in a new table.
**Size:** L. **Priority:** high-leverage add.

### 3.5 No water tracking
**Why it matters.** Nearly every consumer tracker logs water as a first-class metric. We log nothing.
**Suggested direction.** `hydration_entries` table (date, ml). Small ring widget on Today. Quick chips (250 ml / 500 ml / 1 bottle). No goal in v1 — just the count.
**Size:** S. **Priority:** nice-to-have.

---

## 4. Intelligence & insight

### 4.1 The app is a logger, not a coach
**Why it matters.** Once a user has logged for a week, Fulfilled has nothing to tell them. No weekly average vs target. No weight-trend overlay on the goal. No "you've under-shot protein every day this week." MacroFactor's entire value prop is this feedback loop. Without it, month-2 retention is a coin flip.
**Current state.** Today shows today only. Weight chart shows entries with no goal overlay.
**Suggested direction.** Ship a "This week" panel on Today (or a sibling tab) with 7-day avg calories vs target, per-macro avg vs target, weight-trend slope vs `weekly_rate_kg`, and adherence days. Either a new `GET /weeks/{week}/summary` endpoint or computed FE-side from existing data.
**Size:** M. **Priority:** high-leverage add.

### 4.2 No goal-arrival forecast
**Why it matters.** A user setting "lose 0.5 kg/wk to reach 75 kg" wants to know *when*. The math is two lines from `weekly_rate_kg` and `target_weight_kg`; we never display it. Competitors prominently show "at this pace, you'll hit 75 kg by Aug 14."
**Suggested direction.** Add a single line on the goal card: "At your current trend, you'll reach 75 kg around August 14." Use the 7-day moving average weight slope vs target. Decay gracefully ("Log weight for 7 days to see your trend").
**Size:** S. **Priority:** high-leverage add.

### 4.3 Streaks exist in spirit but the pill is mute
**Why it matters.** The week pill is explicitly designed *not* to celebrate (spec forbids animation/scale/fire emoji/haptic at 7/7). That was deliberate, but it leaves the user with no positive reinforcement loop at all. Duolingo's whole product is the streak; we don't need flames, but a "7-day streak" label carries the same emotional weight as the suppressed "1/7" carries the opposite.
**Suggested direction.** Replace the pill with a small "streak: 4 days" indicator that resets at first missed day. Tap opens a 30-day calendar heatmap. Calm enthusiasm, not theme-park gamification.
**Size:** S. **Priority:** high-leverage add.

### 4.4 "Burned" is a stub with no upstream
**Why it matters.** The Today ring's "Burned —" row has never been populated. As-is it advertises a feature we don't have.
**Suggested direction.** Decide whether Fulfilled integrates with HealthKit / Google Fit / Apple Watch / Garmin. If yes, multi-quarter mobile-platform investment. If no, hide the row.
**Size:** L (wire up) / S (hide). **Priority:** must-fix gap to *hide*; future bet to wire.

---

## 5. Trust & accountability

### 5.1 Users can't tell what's measured vs estimated
**Why it matters.** Per-serving kcal for "Apple Pie · Table Talk" is OFF-reported (may be the manufacturer's label or a community estimate). Per-serving kcal for "Test smoothie" is whatever the user typed. The user has no way to know which. Cronometer differentiates with provenance badges.
**Current state.** Source badge (OFF / USDA / YOU) appears on the row; food detail shows "OFF data" / "USDA data" / "Your food" as a subtitle.
**Suggested direction.** Augment with a confidence band — OFF Nutriscore + completeness%, USDA Foundation vs Branded, user-entered with last-edited timestamp. One-line "About this data" sheet behind a tap.
**Size:** M. **Priority:** high-leverage add.

### 5.2 Goal creation silently fails when prerequisites aren't met
**Why it matters.** "New goal" shows "WILL TARGET — kcal/day" with no value when the user has no weight/height/age/sex on file. Save is greyed out with no explanation. The dependency ("we need weight + body data to compute target kcal") is hidden.
**Current state.** Save disabled silently; kcal placeholder doesn't fill until all prerequisites exist.
**Suggested direction.** Replace the disabled Save with a sequence: "Log your current weight" → "Confirm your height" → "Now we can target X kcal/day." Make the dependency legible.
**Size:** S. **Priority:** must-fix gap.

### 5.3 Frozen-snapshot semantics are correct but invisible
**Why it matters.** Per the API, log entries snapshot nutrition at write time — editing the custom food's macros later doesn't change historical entries. Correct, but invisible. A user editing their custom food and expecting Tuesday's entry to update will be surprised.
**Suggested direction.** On the log-entry edit sheet for a `user`-source food, show a subtle "Snapshot from Mon, May 12" caption near the kcal. Bonus: a "Recompute with current values" button.
**Size:** S. **Priority:** nice-to-have.

### 5.4 Token expiry is silent
**Why it matters.** Tokens carry an `expires_at` of ~30 days. The FE explicitly ignores it (`TODO BE-008-refresh: expires_at intentionally ignored in v1`). At day 30, the user opens the app, hits a 401, gets bounced to login with no warning. A habit product just broke the habit silently.
**Suggested direction.** Either wire a refresh-token rotation flow or, at minimum, prompt 3 days before expiry with a "stay signed in" banner that re-auths in place.
**Size:** M. **Priority:** must-fix gap.

---

## 6. Mobile-specific friction

### 6.1 No notifications, widgets, or watch — at all
**Why it matters.** Mobile is where the habit lives. We ship neither push notifications, home/lock screen widgets, nor a watch app. Competitors have all of these.
**Current state.** No `flutter_local_notifications` / `home_widget` / `workmanager` / `firebase_messaging` in `pubspec.yaml`. Mobile-distinct deps are only `mobile_scanner` (barcode) and `flutter_secure_storage` (token).
**Suggested direction.** Pick *one* and ship it well. Recommendation: a configurable daily "log your evening meals" push at 8 pm local. Wave 2: a home-screen widget showing "kcal left today" + a "+ Log food" tap target.
**Size:** M (notifications) / L (widget + watch). **Priority:** high-leverage add.

### 6.2 No share extension — menu photos, receipts, food photos go nowhere
**Why it matters.** A user at a restaurant photos a menu and wants "Share to Fulfilled." A user buys a farmer's-market apple with no barcode and wants to share a photo as a reminder. Both are mobile-distinct moments Fulfilled misses entirely.
**Suggested direction.** v1: accept a photo, attach to a Quick Add with a "review later" flag. No OCR, no AI. v2 (future bet): AI portion estimation from photos — the Cronometer moonshot.
**Size:** M (v1) / L (v2). **Priority:** high-leverage add.

### 6.3 Barcode scanner is built but functionally broken
**Why it matters.** A real-world scan 404s ~99% of the time given §3.1's catalogue depth, then the 404 fallback path crashes per §7.1. The scanner isn't broken because of the scanner; it's broken because of catalogue + routing.
**Suggested direction.** Fix §7.1 and §3.1; the scanner becomes a feature.
**Size:** S (after upstream). **Priority:** must-fix gap.

### 6.4 Offline outbox covers logs but nothing else
**Why it matters.** "Fulfilled works offline" is fragile if it only holds for one verb. Weight, profile patches, goals, custom-food writes are all online-only.
**Suggested direction.** Extend the outbox to weights and profile patches at minimum — same append-only flush semantics as logs.
**Size:** M. **Priority:** nice-to-have.

---

## 7. Engagement & retention

### 7.1 Creating a custom food crashes (P0 bug)
**Why it matters.** The `+` button on My Foods, the no-detect-fallback on the barcode scanner, and any deep link to `/foods/new` all land on a screen that immediately shows "Couldn't load food details" with a raw `DioException: 400` debug snackbar. Cause: go_router matches `/foods/:foodId` before `/foods/new`, so `new` is treated as a food id and the detail resolver fires.
**Current state.** Route precedence bug in `app_router.dart`. The My Foods CTA and the scanner no-detect-hint both navigate to `/foods/new`. Raw DioException text reaches the user.
**Suggested direction.** Re-order or constrain routes so `/foods/new` resolves to the create screen. Globally wrap repository errors in a friendly "Something went wrong" with Retry; never leak raw HTTP error text.
**Size:** S. **Priority:** must-fix gap.

### 7.2 Nothing brings the user back tomorrow
**Why it matters.** No notifications, no email digest, no weekly push, no friend graph, no journaling, no photos. The user has to *remember* to open Fulfilled.
**Suggested direction.** Ship one re-engagement loop. Cheapest big lever: a Sunday evening email or push "Your week in Fulfilled" with avg kcal, weight trend, days logged.
**Size:** M. **Priority:** high-leverage add.

### 7.3 No journaling — calories without context are noise
**Why it matters.** A user logging 2,400 kcal on a 1,800 target wants to remember *why* (wedding / bad day / post-long-run). Log entries have a per-entry `note` field but no day-level journal, tags, or "how did today feel?" prompt.
**Suggested direction.** Add a `consumed_on`-keyed day note ("How did today go?") as an expandable card on Today's bottom. Power users get a journal; everyone else ignores it.
**Size:** S. **Priority:** nice-to-have.

### 7.4 No social / friend graph (intentional?)
**Why it matters.** MyFitnessPal's primary moat is the friend feed — "your wife logged her workout" pushes drive 30%+ of daily opens. Cronometer eschews this and competes on data depth. Fulfilled has neither, so neither moat. A north-star call is overdue: pick social, pick depth, or accept neither — but doing neither is the failure mode.
**Size:** L. **Priority:** future bet.

---

## 8. Monetization-shaped questions

The clearest premium-shaped candidates from this audit:

- **Coaching surfaces** (§4.1, §4.2) — weekly summaries, trend forecasts, "is your goal still right." MacroFactor charges $12/mo for exactly this.
- **AI photo logging** (§6.2 v2) — highest-novelty paid feature in the category right now.
- **Recipe + meal planner** (§3.4) — Plate Joy / Mealime price point.
- **Watch + widget** (§6.1) — reasonable freemium gate.
- **Family / household** — share a plan with a partner. Future bet.

What's *not* premium-shaped: the daily logging loop itself, basic weight tracking, basic goals, the catalogue. Charging for these is product suicide in this category.

**Direction:** don't gate anything in v1.5. Build coaching (§4.1) and v1 photo logging (§6.2) as free features; they're the natural premium gates two releases later when the product has retention to monetize.

---

## 9. Edge cases & polish

### 9.1 No dark mode
The theme tokens layer is *structured* for it (explicit "snap at t=0.5 once dark lands" comments) but there's no theme mode setting and no system follow. A nutrition tracker used at night without dark mode is uncomfortable on phones.
**Suggested direction.** "System / Light / Dark" toggle on the `/me` settings card. The token layer makes this a finite swap, not a rewrite. **Size:** M. **Priority:** high-leverage add.

### 9.2 No localization beyond number formatting
`intl` ships in `pubspec.yaml` but only for decimal separators. All UI copy is English. The catalogue is mostly English-named OFF rows — searching "banana" returns "Banane | Marks And Spencer" because OFF is multilingual and we don't filter by name language. **Size:** L (full i18n) / S (flag/filter non-English OFF rows). **Priority:** future bet.

### 9.3 Error states leak DioException text to users
§7.1 is the worst case but the pattern repeats. Any unhandled 4xx produces a black debug snackbar with MDN links. Developer console output escaped to production. **Suggested direction.** Central HTTP error handling at the repository layer: 401 → "Session expired, sign in again"; 404 → screen-specific empty state; 5xx → "Something went wrong, retry"; everything else → "Couldn't complete that." Never raw stack traces. **Size:** S. **Priority:** must-fix gap.

### 9.4 Pagination invisible — users think the catalogue is 100 items deep
"apple" returns 360, "milk" 794, "cheese" 1554. Server clamps to 100; FE shows them with no "Showing X of Y" or "Load more." Users assume the catalogue is small. **Suggested direction.** "Showing 100 of 360" at the bottom of the list + "Load more" button or scroll-paginate. **Size:** S. **Priority:** high-leverage add.

### 9.5 Today's "Weight · last 30 days" card renders for users with no weight history
A first-run user sees a card promising a trend they don't have. Amplifies the "hollow app" feeling on day one. **Suggested direction.** Hide the card on Today when weight count is 0; reintroduce on first entry. `/weight` tab still owns its own empty state. **Size:** S. **Priority:** nice-to-have.

---

## 10. Things that surprised me

**The PM specs in `server/specs/pm_*.md` already anticipate much of this audit.** A dozen+ docs (`pm_overnight_features`, `pm_qol_audit`, `audit_followup_pm`) name many of these gaps. The team isn't unaware — the bottleneck is *spec-to-ship latency*, not idea generation. The biggest leverage in the next planning meeting may be project management discipline (closing the loop), not product discovery.

**The data model is unusually right.** The Ask-10 reshape (per-serving nutrition, frozen log snapshots with `entered_amount + entered_unit` denorm for replayability, multi-serving foods with `is_default`) is a better model than every competitor I've seen in the space. Almost every feature opportunity in this doc is "use what's already modelled," not "rebuild the foundation." The schema-design cost has been paid.

**"Banane" for "banana" is a category-defining miss.** OFF being multilingual means we serve "Banane | Marks And Spencer" as a top hit for an English query. Either monolingual-filter at search time (cheap, lossy) or project translated names onto a canonical English surface (expensive, correct). It's invisible until you see it; it's then a top-3 ranking issue.

**The login screen says "Sign in to your server."** A self-hosted OIDC handoff to Authentik with that header is jarring for a consumer-shaped product. Either Fulfilled is self-hosted-first (lean in — "Your server, your data" is a real differentiator vs. MyFitnessPal) or consumer SaaS (reskin the Authentik flow heavily). The current ambiguity does neither well.

**The `extra_nutrients` JSONB column is unused.** The schema reserves space for free-form additional nutrient data (omega-3, B12, magnesium). Cronometer's whole edge is "we track 80+ nutrients, not 4." Dormant capacity for a future "Full Nutrition Mode" differentiator — already in the schema, kept warm for the moment we want to compete on data depth instead of usability.

---

## Appendix: the build-vs-fix triage

If the next sprint can hold exactly five items, take from the must-fix list first:

1. §2.1 — fix the search-row kcal contract drift (S)
2. §7.1 — fix `/foods/new` route precedence + leaked DioException (S)
3. §1.1 — gate first-time authenticated users into `/onboarding/1` (S)
4. §3.2 — populate USDA serving labels from the FDC source (S)
5. §2.2 — quality-bias the search ranker (M)

Four S, one M. None require new schema. All five compound: once search works, custom-food creation works, and onboarding routes correctly, the product is demoable end-to-end without caveats. *Then* we get to talk about coaching, notifications, and recipes.
