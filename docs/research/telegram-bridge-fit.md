# Telegram Bridge Fit Research

## Summary

The old Telegram bridge commit from `~/proj/viche` was conceptually relevant but not directly portable.

## Main mismatches found

- Old code used composite Telegram-derived agent IDs.
- Current codebase persists agent ownership in `agents` records keyed by UUID.
- Current router and API layer include authenticated browser/API flows and agent ownership checks.
- Private registry access is user-scoped through web auth and invitations, not chat-delivered secrets.

## Resulting design choices

- Keep UUID agent IDs.
- Store Telegram identity in separate persistence tables.
- Use browser pairing to claim a Telegram-created agent and join registries.
- Keep the feature user-driven and avoid a separate Telegram admin surface.
- Keep Telegram-backed agents online by using the existing always-online websocket status model until explicit deregistration.
- Invalidate any previous pairing link when a new one is generated.

## Additional compatibility work needed

- Claiming an agent must update both persisted ownership and live registry metadata.
- Dynamic registry joins must be persisted so paired Telegram agents can be restored.
- Persisted Telegram-linked agents need a reactivation path after restart.
