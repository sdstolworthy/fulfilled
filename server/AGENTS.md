# Agent instructions

## Keep the OpenAPI spec in sync with HTTP routes

`specs/openapi.yaml` is the source of truth for the public HTTP surface and is
consumed by clients. **Whenever you change anything that affects the wire
shape, update `specs/openapi.yaml` in the same change.**

This applies to any of the following:

- Adding, removing, or renaming a route in `crates/loseit-api/src/routes/`.
- Changing a path parameter, query parameter, or HTTP method.
- Adding, removing, or renaming a field on a request or response DTO
  (anything `#[derive(Serialize)]` or `#[derive(Deserialize)]` in the routes
  module, or any flattened/nested type it references).
- Changing a field's type, nullability, or whether it's required.
- Adding a new enum variant to a domain enum that appears on the wire
  (`Sex`, `ActivityLevel`, `Meal`, `FoodSource`, `ServingSource`,
  `NutriscoreGrade`).
- Adding or changing a status code, or changing the mapping in
  `crates/loseit-api/src/error.rs` between `CoreError` / `AuthError` and
  HTTP responses.
- Changing authentication requirements on a route (e.g. moving it between
  the public and authed sub-routers in `server.rs`).

When updating the spec:

1. Edit `specs/openapi.yaml` alongside the code change — not in a follow-up.
2. Reuse existing `components/schemas` entries where possible; only add a
   new schema when the shape is genuinely new.
3. Validate the spec parses before committing:

   ```sh
   python3 -c "import yaml; yaml.safe_load(open('specs/openapi.yaml'))"
   ```

4. If you add or remove a route, also confirm the `tags` and the path's
   placement under the correct tag still make sense.

If a change is purely internal (service plumbing, repo layer, SQL,
non-wire DTOs) it does not require a spec update.

## Flutter client location

The deploy workflow at `.github/workflows/pages.yml` expects the Flutter
client to live at the repo-root `app/` directory and to be a standard
Flutter project (i.e. `app/pubspec.yaml` must exist).

When that file is present the workflow runs `flutter build web --release
--base-href "/<repo>/app/"` and publishes the output at
`https://<owner>.github.io/<repo>/app/`. While it's absent, the
workflow publishes a placeholder from `.github/pages/app-stub/`.

If you scaffold the Flutter project somewhere else, update both
`.github/workflows/pages.yml` (the `app/pubspec.yaml` detection and the
`cd app` build step) and this note so the deploy keeps working.
