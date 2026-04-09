## Private Registries for Viche

### Summary
Implement private registries — isolated namespaces where users can host agents without exposure to the public network.

### What's Changed

**Schema** (`lib/viche/registries/registry.ex`)
- New `Registry` model with binary_id primary key
- Fields: name, slug, description, is_private (default: true)
- Belongs_to :owner (User) with `on_delete: :delete_all`
- Unique constraint + regex validation on slug: `~r/^[a-z0-9][a-z0-9-]{2,50}$/`
- Auto-downcase slugs in changeset

**Context** (`lib/viche/registries.ex`)
- `list_user_registries/1` — Fetch user's registries (indexed on owner_id)
- `get_registry/1`, `get_registry_by_slug/1`, `get_user_registry/2` — Lookups
- `create_registry/2`, `update_registry/2`, `delete_registry/1` — Full CRUD
- `well_known_url/1` — Generate `.well-known/agent-registry` URLs for agent connectivity

**Migration** (`priv/repo/migrations/20260405000001_create_registries.exs`)
- Unique index on slug
- FK constraint with cascade delete
- Indexed owner_id

**LiveView** (`lib/viche_web/live/registries_live.ex`)
- Mobile-friendly UI with slide-out menu support
- Create/delete modals with proper `phx-click-away` handling
- Form validation with live feedback
- Copy-to-clipboard for well-known URLs

### Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| FK on_delete | `:delete_all` | Registries must be deleted with their owner |
| Primary key | `binary_id` | Consistent with User schema; safe for external exposure |
| Optimistic locking | Not needed | Single-owner resources; no concurrent edits |
| Slug validation | Regex + unique index | DB-level protection against duplicates |

### Testing
- **463 tests passing** (including 28 new registry tests)

### Bugs Fixed During Review
1. Missing `mobile_menu_open` assign in mount/3 → added
2. Modal auto-closing on input focus → fixed `phx-click-away` placement on backdrop
3. Missing `has_many :registries` in User schema → added
4. `downcase_slug` running on every update → changed to `update_change` with slug-in-changes check

### Related Files
- `lib/viche/registries/registry.ex`
- `lib/viche/registries.ex`
- `lib/viche_web/live/registries_live.ex`
- `lib/viche_web/live/registries_live.html.heex`
- `lib/viche_web/live/registry_detail_live.ex`
- `lib/viche_web/live/registry_detail_live.html.heex`
- `lib/viche_web/live/registry_scope.ex`
- `lib/viche_web/controllers/registry_controller.ex`
- `priv/repo/migrations/20260405000001_create_registries.exs`

### Future Work
- Registry-to-registry agent discovery
- Custom domain support per registry
- Registry sharing/permissions
