# Telegram Bridge Pairing Tasks

- [x] Add Telegram DB migrations for agent links and pairing tokens
- [x] Add Telegram schemas and context functions
- [x] Add atomic claim operation for unowned agents
- [x] Add Telegram API client module
- [x] Add Telegram bridge GenServer and application startup wiring
- [x] Add pairing browser flow and login handoff
- [x] Keep Telegram agents online until explicit deregistration
- [x] Remove paired Telegram agents from `global`
- [x] Disable pairing when auth is off
- [x] Keep only one active pairing token per Telegram agent
- [x] Add tests for context, bridge, and pairing
- [x] Run `mix precommit`
