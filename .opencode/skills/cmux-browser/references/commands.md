# cmux Browser Command Reference

All browser commands follow the pattern:

```
cmux browser <subcommand> --surface "$CMUX_BROWSER_SURFACE" [flags]
```

---

## Navigation

### navigate

Load a URL in the browser surface.

```bash
cmux browser navigate --surface "$CMUX_BROWSER_SURFACE" "<url>"

# Examples
cmux browser navigate --surface "$CMUX_BROWSER_SURFACE" "http://localhost:4000"
cmux browser navigate --surface "$CMUX_BROWSER_SURFACE" "http://localhost:4000/users/new"
cmux browser navigate --surface "$CMUX_BROWSER_SURFACE" "about:blank"
```

### reload

Reload the current page.

```bash
cmux browser reload --surface "$CMUX_BROWSER_SURFACE"

# Hard reload (ignore cache)
cmux browser reload --surface "$CMUX_BROWSER_SURFACE" --ignore-cache
```

### back / forward

Navigate browser history.

```bash
cmux browser back --surface "$CMUX_BROWSER_SURFACE"
cmux browser forward --surface "$CMUX_BROWSER_SURFACE"
```

### open

Open a new browser surface. Returns JSON with `browser_ref`.

```bash
cmux --json browser open "http://localhost:4000"
cmux --json browser open "about:blank"
```

---

## Snapshot (Accessibility Tree)

Preferred way to inspect page structure — returns the a11y tree with `uid`
values for every interactive element.

```bash
# Standard snapshot
cmux browser snapshot --surface "$CMUX_BROWSER_SURFACE"

# Verbose (all a11y properties)
cmux browser snapshot --surface "$CMUX_BROWSER_SURFACE" --verbose

# Save snapshot to file
cmux browser snapshot --surface "$CMUX_BROWSER_SURFACE" --output /tmp/snap.txt
```

Snapshot output format:

```
[uid=abc123] button "Sign in" (focused)
[uid=def456] input "Email" value=""
[uid=ghi789] input "Password" value=""
[uid=jkl012] link "Forgot password?" href="/reset"
```

---

## Wait

Poll until a condition is met (avoids fragile sleep calls).

```bash
# Wait for CSS selector to exist in DOM
cmux browser wait --surface "$CMUX_BROWSER_SURFACE" --selector "h1"
cmux browser wait --surface "$CMUX_BROWSER_SURFACE" --selector ".flash-info"

# Wait for text to appear anywhere on page
cmux browser wait --surface "$CMUX_BROWSER_SURFACE" --text "Successfully saved"

# Custom timeout in milliseconds (default 5000)
cmux browser wait --surface "$CMUX_BROWSER_SURFACE" --selector ".results" --timeout 10000
```

---

## Interaction

### click

```bash
# By CSS selector
cmux browser click --surface "$CMUX_BROWSER_SURFACE" --selector "button[type=submit]"
cmux browser click --surface "$CMUX_BROWSER_SURFACE" --selector "a[href='/logout']"
cmux browser click --surface "$CMUX_BROWSER_SURFACE" --selector ".menu-item:nth-child(2)"

# By uid from snapshot
cmux browser click --surface "$CMUX_BROWSER_SURFACE" --uid "<uid>"

# Double click
cmux browser click --surface "$CMUX_BROWSER_SURFACE" --selector ".editable-cell" --double
```

### fill

Type text into an input, textarea, or select an option from `<select>`.

```bash
# Input by selector
cmux browser fill --surface "$CMUX_BROWSER_SURFACE" --selector "input[name=email]" --value "user@example.com"
cmux browser fill --surface "$CMUX_BROWSER_SURFACE" --selector "textarea[name=body]" --value "Hello world"

# Select dropdown
cmux browser fill --surface "$CMUX_BROWSER_SURFACE" --selector "select[name=role]" --value "admin"

# By uid
cmux browser fill --surface "$CMUX_BROWSER_SURFACE" --uid "<uid>" --value "text"
```

### press-key

Send a keyboard key to the focused element or page.

```bash
cmux browser press-key --surface "$CMUX_BROWSER_SURFACE" "Enter"
cmux browser press-key --surface "$CMUX_BROWSER_SURFACE" "Tab"
cmux browser press-key --surface "$CMUX_BROWSER_SURFACE" "Escape"
cmux browser press-key --surface "$CMUX_BROWSER_SURFACE" "Control+A"
cmux browser press-key --surface "$CMUX_BROWSER_SURFACE" "Control+Enter"
```

### hover

Move the pointer over an element (triggers CSS :hover, tooltips, etc.).

```bash
cmux browser hover --surface "$CMUX_BROWSER_SURFACE" --selector ".tooltip-trigger"
cmux browser hover --surface "$CMUX_BROWSER_SURFACE" --uid "<uid>"
```

### drag

Drag one element onto another.

```bash
cmux browser drag --surface "$CMUX_BROWSER_SURFACE" --from-uid "<uid-source>" --to-uid "<uid-target>"
```

---

## Visibility

Check whether an element is present and visible.

```bash
# Returns exit code 0 if visible, non-zero if not
cmux browser visible --surface "$CMUX_BROWSER_SURFACE" --selector ".error-message"

# Use in conditionals
if cmux browser visible --surface "$CMUX_BROWSER_SURFACE" --selector ".flash-error"; then
  echo "Error flash is visible"
fi
```

---

## Data Extraction

### eval — Execute JavaScript

```bash
# Synchronous
cmux browser eval --surface "$CMUX_BROWSER_SURFACE" "document.title"
cmux browser eval --surface "$CMUX_BROWSER_SURFACE" "document.querySelectorAll('tr').length"
cmux browser eval --surface "$CMUX_BROWSER_SURFACE" "window.location.pathname"
cmux browser eval --surface "$CMUX_BROWSER_SURFACE" "document.cookie"

# Async (use await)
cmux browser eval --surface "$CMUX_BROWSER_SURFACE" "await fetch('/api/health').then(r => r.json())"

# Complex expression
cmux browser eval --surface "$CMUX_BROWSER_SURFACE" \
  "Array.from(document.querySelectorAll('h2')).map(el => el.textContent)"
```

---

## Console Messages

```bash
# All messages since last navigation
cmux browser console --surface "$CMUX_BROWSER_SURFACE"

# Filtered by type: log | debug | info | warn | error
cmux browser console --surface "$CMUX_BROWSER_SURFACE" --type error
cmux browser console --surface "$CMUX_BROWSER_SURFACE" --type warn

# Get specific message by ID (from list output)
cmux browser console --surface "$CMUX_BROWSER_SURFACE" --id <msgid>
```

---

## Network Requests

```bash
# List all requests since last navigation
cmux browser network --surface "$CMUX_BROWSER_SURFACE"

# Filter by resource type: document | stylesheet | image | script | fetch | xhr | websocket | other
cmux browser network --surface "$CMUX_BROWSER_SURFACE" --type fetch
cmux browser network --surface "$CMUX_BROWSER_SURFACE" --type xhr

# Get request/response details by ID
cmux browser network --surface "$CMUX_BROWSER_SURFACE" --id <reqid>

# Save response body to file
cmux browser network --surface "$CMUX_BROWSER_SURFACE" --id <reqid> --response-file /tmp/body.json
```

---

## Screenshots

```bash
# Inline screenshot (attached to response for analysis)
cmux browser screenshot --surface "$CMUX_BROWSER_SURFACE"

# Save to file
cmux browser screenshot --surface "$CMUX_BROWSER_SURFACE" --output /tmp/screenshot.png

# Full-page screenshot (scrolls and stitches)
cmux browser screenshot --surface "$CMUX_BROWSER_SURFACE" --full-page

# Element-only screenshot
cmux browser screenshot --surface "$CMUX_BROWSER_SURFACE" --selector ".chart-container"

# Format options: png (default), jpeg, webp
cmux browser screenshot --surface "$CMUX_BROWSER_SURFACE" --format jpeg --quality 85
```

---

## Scrolling

```bash
# Scroll to bottom of page
cmux browser eval --surface "$CMUX_BROWSER_SURFACE" "window.scrollTo(0, document.body.scrollHeight)"

# Scroll to top
cmux browser eval --surface "$CMUX_BROWSER_SURFACE" "window.scrollTo(0, 0)"

# Scroll element into view
cmux browser eval --surface "$CMUX_BROWSER_SURFACE" \
  "document.querySelector('.footer').scrollIntoView()"
```

---

## Dialogs

Handle alert/confirm/prompt dialogs triggered by JS.

```bash
# Accept (OK)
cmux browser dialog --surface "$CMUX_BROWSER_SURFACE" --action accept

# Dismiss (Cancel)
cmux browser dialog --surface "$CMUX_BROWSER_SURFACE" --action dismiss

# Accept with text (for prompt dialogs)
cmux browser dialog --surface "$CMUX_BROWSER_SURFACE" --action accept --text "my input"
```

---

## Close Browser Surface

```bash
cmux close-surface --surface "$CMUX_BROWSER_SURFACE"
```
