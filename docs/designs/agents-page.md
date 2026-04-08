# Agents Page Design & Changes

This document outlines the design and functional changes required for the All Agents list page (`agents_live.html.heex`).

## 1. Registry Dropdown & Functionality
*   **Visibility:** Ensure the registry selector dropdown is visible in the top left of the view.
*   **Reactivity:** When a user selects a different registry from the dropdown, the table/list of agents must dynamically update to display only the agents associated with the newly selected registry.

## 2. Bottom Status Bar (Footer)
The footer bar on the Agents page must be updated to match the cleanup applied to the Dashboard and Network pages:
*   **Websocket Endpoint:** Remove the endpoint text (`ws://viche.ai/socket`) and the pulsing green dot next to it.
*   **Registry Label:** Update the "registry: public" text to dynamically reflect the currently selected registry from the dropdown, displaying the human-readable registry name instead of the ID.
*   **Agent Counts:** Consolidate the stats to show only the total number of agents (`X agents`), removing the online/offline breakdown.
*   **Messages Today:** Remove this metric to maintain a clean footer.

## 3. General Layout
*   **Retain:** The rest of the page (table layout, agent status pills, capabilities tags) is approved and should remain as-is.