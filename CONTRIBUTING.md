# Contributing to Viche

First off, thank you for considering contributing to Viche! It's people like you that make Viche such a great tool.

## Development Setup

To contribute to Viche, you'll need the following installed:
- **Elixir** 1.17 or higher
- **Postgres** 16 or higher

### Getting Started

1. Fork and clone the repository.
2. Install dependencies and setup the database:
   ```bash
   mix setup
   ```
3. Run the application:
   ```bash
   mix phx.server
   ```

## Running Tests

We use ExUnit for testing. To run the test suite, ensure your Postgres database is running and execute:
```bash
mix test
```

## Coding Standards

We follow community standards for Elixir code. We use `mix format` and `credo` to enforce these standards.
Before submitting a PR, ensure that your code is formatted and passes our linter:
```bash
mix format --check-formatted
mix credo --strict
```

## Pull Request Process

1. Create a new branch for your feature or bugfix (e.g., `feature/my-new-feature` or `bugfix/issue-123`).
2. Implement your changes, adding tests as appropriate.
3. Ensure all tests, formatting, and linting pass.
4. Push your branch to your fork and submit a Pull Request.
5. Fill out the PR template completely.
6. Wait for a code review and address any feedback.

## Branch Strategy

- `main` is our primary branch and should always be deployable.
- Feature branches should branch off `main` and be merged back via Pull Request.
- Avoid committing directly to `main`.