# cmux Terminal Interaction Reference

## read-screen — Capture Terminal Output

Read the visible buffer of any surface.

```bash
# Last N lines (default varies by version)
cmux read-screen --surface "$CMUX_SERVER_SURFACE" --lines 100

# Full visible viewport
cmux read-screen --surface "$CMUX_SERVER_SURFACE"

# Capture to a variable for processing
output=$(cmux read-screen --surface "$CMUX_SERVER_SURFACE" --lines 50)
echo "$output" | grep -i "error"
```

### Phoenix-specific: Read server log

```bash
# Check for compilation errors
cmux read-screen --surface "$CMUX_SERVER_SURFACE" --lines 40 | grep -E "(error|warning|Error)"

# Check if server booted successfully
cmux read-screen --surface "$CMUX_SERVER_SURFACE" --lines 20 | grep "Running LaunchclawWeb.Endpoint"

# Capture test output after running mix test
cmux read-screen --surface "$CMUX_SERVER_SURFACE" --lines 100 | grep -E "(\d+ tests|Finished)"
```

---

## send — Type Text Into a Surface

Sends a string of characters as if typed. Include `\n` at the end to submit.

```bash
# Run a mix command
cmux send --surface "$CMUX_SERVER_SURFACE" "iex -S mix phx.server\n"

# Run database migration
cmux send --surface "$CMUX_SERVER_SURFACE" "mix ecto.migrate\n"

# Run tests
cmux send --surface "$CMUX_SERVER_SURFACE" "mix test\n"

# Run a single test file
cmux send --surface "$CMUX_SERVER_SURFACE" "mix test test/launchclaw_web/controllers/page_controller_test.exs\n"

# Open IEx
cmux send --surface "$CMUX_SERVER_SURFACE" "iex -S mix\n"

# Type without submitting (no \n)
cmux send --surface "$CMUX_SERVER_SURFACE" "mix test "
```

---

## send-key — Send Special Keys

Send keyboard shortcuts or special keys that can't be typed as text.

```bash
# Interrupt running process (like Ctrl-C)
cmux send-key --surface "$CMUX_SERVER_SURFACE" ctrl-c

# Clear the terminal
cmux send-key --surface "$CMUX_SERVER_SURFACE" ctrl-l

# Navigate history
cmux send-key --surface "$CMUX_SERVER_SURFACE" up
cmux send-key --surface "$CMUX_SERVER_SURFACE" down

# Tab completion
cmux send-key --surface "$CMUX_SERVER_SURFACE" tab

# Enter without send
cmux send-key --surface "$CMUX_SERVER_SURFACE" enter
```

Common key names: `ctrl-c`, `ctrl-d`, `ctrl-l`, `ctrl-z`, `enter`, `tab`,
`escape`, `up`, `down`, `left`, `right`, `backspace`, `delete`, `page-up`,
`page-down`.

---

## Phoenix Server Workflows

### Full restart cycle

```bash
cmux send-key --surface "$CMUX_SERVER_SURFACE" ctrl-c
sleep 1
cmux send --surface "$CMUX_SERVER_SURFACE" "iex -S mix phx.server\n"
# Wait for boot
sleep 4
cmux read-screen --surface "$CMUX_SERVER_SURFACE" --lines 10
```

### Run migrations then restart

```bash
cmux send-key --surface "$CMUX_SERVER_SURFACE" ctrl-c
sleep 1
cmux send --surface "$CMUX_SERVER_SURFACE" "mix ecto.migrate && iex -S mix phx.server\n"
```

### Check if server is healthy

```bash
output=$(cmux read-screen --surface "$CMUX_SERVER_SURFACE" --lines 5)
if echo "$output" | grep -q "Running LaunchclawWeb.Endpoint"; then
  echo "Server is up"
else
  echo "Server may not be running — check output"
  echo "$output"
fi
```

### Run precommit validation in server pane

```bash
cmux send-key --surface "$CMUX_SERVER_SURFACE" ctrl-c
sleep 1
cmux send --surface "$CMUX_SERVER_SURFACE" "mix precommit\n"
sleep 30
cmux read-screen --surface "$CMUX_SERVER_SURFACE" --lines 50
```

---

## Tips

- Always `ctrl-c` before sending a new command if the pane may be busy
- Use `sleep` between `send-key ctrl-c` and `send` to allow the shell to
  return to the prompt — typically 0.5–1s is enough
- `read-screen` reads the *visible* buffer; scroll-back history is not
  accessible via this command
- For long-running commands, wait (sleep) then read-screen rather than
  trying to stream output
