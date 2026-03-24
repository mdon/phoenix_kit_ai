# PR #1: Extract AI module from PhoenixKit into standalone package

**Author**: @mdon
**Status**: Merged
**Commit**: `e6c1415`
**Date**: 2026-03-24

## Goal

Extract the AI module from the PhoenixKit monolith into a standalone Hex package (`phoenix_kit_ai`), following the same pattern as other PhoenixKit modules (catalogue, newsletters, posts, etc.). This enables independent versioning, testing, and deployment of AI functionality.

## What Was Changed

### Files Modified

| File | Change |
|------|--------|
| `lib/phoenix_kit_ai.ex` | Main module: PhoenixKit.Module behaviour + full context (endpoints, prompts, requests, completions) |
| `lib/phoenix_kit_ai/endpoint.ex` | Ecto schema for AI endpoint configurations |
| `lib/phoenix_kit_ai/prompt.ex` | Ecto schema for prompt templates with `{{Variable}}` substitution |
| `lib/phoenix_kit_ai/request.ex` | Ecto schema for request logging (tokens, cost, latency) |
| `lib/phoenix_kit_ai/completion.ex` | HTTP client for OpenRouter chat completions and embeddings |
| `lib/phoenix_kit_ai/openrouter_client.ex` | API key validation, model discovery, header building |
| `lib/phoenix_kit_ai/ai_model.ex` | Normalized struct for OpenRouter model data |
| `lib/phoenix_kit_ai/routes.ex` | Route module providing admin sub-routes |
| `lib/phoenix_kit_ai/migrations/v1.ex` | Consolidated migration with IF NOT EXISTS for all 3 tables |
| `lib/phoenix_kit_ai/web/*.ex` | Admin LiveViews: Endpoints, EndpointForm, Prompts, PromptForm, Playground |
| `mix.exs` | Package config, dependencies, metadata |
| `test/` | Behaviour compliance test suite + prompt unit tests |

### Schema Changes

Three new tables created by the consolidated migration:

- `phoenix_kit_ai_endpoints` — UUIDv7 PK, provider credentials, model config, generation parameters
- `phoenix_kit_ai_prompts` — UUIDv7 PK, template content with variable substitution
- `phoenix_kit_ai_requests` — UUIDv7 PK, request logs for usage tracking (tokens, cost in nanodollars, latency)

## Implementation Details

- **Namespace rename**: `PhoenixKit.Modules.AI.*` → `PhoenixKitAI.*`
- **PhoenixKit.Module behaviour**: Implements all required callbacks (`key/0`, `admin_tabs/0`, `enabled?/0`, `permission_metadata/0`, etc.)
- **Route integration**: `route_module/0` returns `PhoenixKitAI.Routes` with `admin_routes/0` and `admin_locale_routes/0`
- **CSS scanning**: `css_sources/0` returns `[:phoenix_kit_ai]` for Tailwind purge support
- **Migration safety**: Uses `IF NOT EXISTS` throughout; checks for existing tables/indexes before creation
- **LayoutWrapper removal**: Admin LiveViews no longer wrap themselves — PhoenixKit applies it via `on_mount`
- **Locale redirect fix**: Endpoints LiveView prevents 302 loop with locale-aware redirect logic
- **Cost precision**: Costs stored in nanodollars (integer) to avoid float precision loss with cheap API calls

## Testing

- [x] Behaviour compliance test suite (all PhoenixKit.Module callbacks)
- [x] Prompt unit tests (variable extraction, substitution, validation)
- [ ] HTTP client error scenarios (not covered)
- [ ] LiveView integration tests (not covered)
- [ ] Migration rollback testing

## Related

- Migration: `lib/phoenix_kit_ai/migrations/v1.ex`
- Parent project: `../phoenix_kit/`
