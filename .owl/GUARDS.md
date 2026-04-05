# Project Guardrails

These guardrails define constraints that all agents working on this project must respect.

## Production
- **NEVER** push directly to production branches
- **NEVER** modify production configuration without explicit approval
- **ALWAYS** route production changes through the standard review process

## Version Control
- Commit messages must be descriptive and follow conventional commits format
- **NEVER** force push to shared branches
- Create feature branches for all non-trivial changes

## Custom Rules
- Agents cannot merge prs. Do no use fly command line tool to access production database or to deploy the application ever. All UI changes should be thought through so that they look good on mobile, while maintaining the core colors and design
