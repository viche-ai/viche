# Settings Page Design & Changes

This document outlines the changes required for the Settings page and its visibility in the application.

## 1. Hide the Settings Page
Currently, the application does not have any functional settings to expose to the user, making the page unnecessary at this stage.
*   **Action:** Do not delete the page/code. Instead, comment out the routing and page code so it is hidden but easily recoverable in the future.
*   **Action:** Remove the `Settings` link from the global sidebar navigation. 

## 2. Updated Sidebar Flow
With the Settings link removed (and the Demo section previously removed), the sidebar layout will now flow directly from the main navigation items (ending with `My Registries` or equivalent main navigation items) down to the pinned `GitHub` link at the very bottom.