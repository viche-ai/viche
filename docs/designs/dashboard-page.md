# Dashboard Page Design & Changes

This document outlines the design, layout, and component changes required for the main Dashboard view (`dashboard_live.html.heex`).

## 1. Registry Dropdown
*   **Visibility:** Ensure the registry selector dropdown (recently added by Ehor to the top left) is consistently visible across the Dashboard and universally throughout the app where applicable. 

## 2. Stat Cards (Top Row)
*   **Total Agents:** Retain this card.
*   **Online vs Registered:** Remove this card entirely (registration tracking is not needed here).
*   **Queued Messages / Messages Today:** Remove these cards. They are not persisted and don't provide significant long-term value to the user.
*   *Note: Removing these 3 cards will leave only "Total Agents" at the top of the grid. See the Layout Restructuring section below for how to re-arrange this space.*

## 3. Connected Agents Panel
*   **Header Actions:** Remove the `Filter`, `Sort`, and `+ Register` buttons/icons from the top right of this panel. They are currently non-functional icons and clutter the UI.

## 4. Live Activity Panel
*   **Header Actions:** Remove the `Pause` button from the top right of the panel.

## 5. Bottom Status Bar (Footer)
*   **Websocket Endpoint:** Remove the endpoint text (`ws://viche.ai/socket`) and the pulsing green dot next to it.
*   **Registry Label:** Update the "registry: public" text. It should dynamically reflect the currently selected registry from the top-left dropdown (showing the human-readable registry name, not the raw ID).
*   **Agent Counts:** Consolidate the agent stats. Instead of `X agents · Y online`, simplify this to just show `X agents`.
*   **Messages Today:** This can be safely removed from the footer to declutter the bar.

## 6. Layout Restructuring (New Layout)
Instead of a top row of stat cards above a split 2-column grid, refactor the page into a unified two-column layout:
*   **Left Column (Wide):**
    *   Takes up ~75% (3/4) of the available width.
    *   Contains the **Connected Agents** panel.
*   **Right Column (Narrow):**
    *   Takes up ~25% (1/4) of the available width.
    *   Contains the **Total Agents** stat card at the top.
    *   Contains the **Live Activity** panel directly beneath it. 
    *   *Note: This cleans up the dead space left by deleting the other 3 stat cards.*