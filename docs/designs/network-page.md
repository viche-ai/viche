# Network Page Design & Changes

This document outlines the design and functional changes required for the Network visualization page (`network_live.html.heex`).

## 1. Registry Dropdown & Functionality
*   **Visibility:** The registry selector dropdown (currently missing on this page) must be added to the top left of the view, ensuring consistency with the rest of the application.
*   **Reactivity:** When a user selects a different registry from the dropdown, the network visualization graph must dynamically update to reflect the specific agents and configuration belonging to that selected registry.

## 2. Bottom Status Bar (Footer)
The footer bar on the Network page must be updated to match the exact cleanup applied to the Dashboard page:
*   **Websocket Endpoint:** Remove the endpoint text (`ws://viche.ai/socket`) and the pulsing green dot next to it.
*   **Registry Label:** Update the "registry: public" text to dynamically reflect the currently selected registry from the dropdown. It must display the human-readable registry name, not the raw registry ID.
*   **Agent Counts:** Consolidate the stats to show only the total number of agents (`X agents`), removing the online/offline breakdown.
*   **Messages Today:** Remove this metric to maintain a clean and consistent footer across the app.