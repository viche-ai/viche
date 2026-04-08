# Registries & Registry Detail Pages Design & Changes

This document outlines the design and consistency changes required for the Registries list page and the individual Registry Detail page.

## 1. Global Footer Addition
Currently, both the `/registries` page and the `/registries/:id` page are completely missing the bottom status bar (footer).
*   **Action:** Add the standardized bottom status bar to both pages for global consistency.
*   **Footer Requirements:** Ensure the new footer adheres to the updated app-wide standard (No websocket endpoint, show selected registry name, show only total agent count, remove "Messages Today").

## 2. Global Header/Topbar Fixes
*   **Missing Theme Toggle:** The Light/Dark mode toggle switch is currently missing from the topbar on both the `/registries` (My Registries) page and the `/registries/:id` (Registry Detail) page. 
*   **Action:** Add the standard theme toggle to the top-right corner of the topbar on both pages to maintain consistency with the rest of the application.

## 3. Registries List Page (`/registries`)
*   **Retain:** The layout, design, and functionality of this page are approved and should remain exactly as-is (with the addition of the footer and theme toggle).

## 4. Registry Detail Page (`/registries/:id`)
*   **Remove "Registration Example" Card:** Scroll to the bottom of the registry detail page and completely remove the "Registration Example" card/block.
*   **NEW FEATURE: Invite Users Card:** Add a new card or distinct section labeled "Invite users". 
    *   **Interaction:** Clicking this should open a modal.
    *   **Modal Functionality:** The modal must allow the current user to input a list of email addresses. 
    *   **Workflow:** Submitting the modal will send email invitations. If the recipient is not a user, they will be prompted to create an account and join the registry. If they are an existing user, they will directly join the registry.
    *   **Sidebar Integration:** Once an invited user joins, this specific registry must automatically appear in their top-left registry dropdown menu in the sidebar.