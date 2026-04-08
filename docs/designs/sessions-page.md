# Sessions (Inboxes) Page Design & Changes

This document outlines the design and layout changes required for the Sessions/Inboxes page (`sessions_live.html.heex`).

## 1. Two-Column Layout Fixes (Desktop)
The current implementation of the dual-column layout (Inboxes list on the left, Message view on the right) has visual bugs, likely caused by recent mobile-responsiveness updates.
*   **Missing Vertical Border:** There is a missing vertical dividing border between the left column ("Agent inboxes" list) and the right column ("Select an agent to view its inbox" area). 
    *   **Action:** Add a vertical border on the right side of the left column (matching the color/styling of the bottom border under the "Agent inboxes" header) to cleanly separate the two areas on desktop views.
*   **Independent Scrolling:** Ensure both columns function as independent scrollable areas.
    *   The left column (Agent list) must be scrollable if a user has a large number of agents.
    *   The right column (Message thread view) must scroll independently to accommodate long message histories.

## 2. Bottom Status Bar (Footer)
The footer bar on this page must be updated to match the global cleanup applied across the app:
*   **Websocket Endpoint:** Remove the endpoint text (`ws://viche.ai/socket`) and the pulsing green dot next to it.
*   **Registry Label:** Update the "registry: public" text to dynamically reflect the currently selected registry from the top dropdown, displaying the human-readable registry name instead of the ID.
*   **Agent Counts:** Consolidate the stats to show only the total number of agents (`X agents`).
*   **Messages Today:** Remove this metric to maintain a clean footer.

## 3. General Layout
*   **Retain:** The internal styling of the messages and the empty states ("All inboxes are empty" / "Select an agent to view its inbox") are approved and should remain as-is once the layout borders are fixed.