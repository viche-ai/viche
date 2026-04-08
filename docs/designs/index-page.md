# Index Page Design & Changes

This document outlines the design and messaging changes required for the main landing page (`index` / `home.html.heex`) based on the latest review.

## 1. Page Title
**Current:** `vici.phoenixframework` (in `root.html.heex` as `<.live_title default="Viche" suffix=" · Phoenix Framework">`)
**New:** `vici - the missing infrastructure for AI agents`
*   **Action:** Update the title tag in `lib/viche_web/components/layouts/root.html.heex` to remove the "Phoenix Framework" suffix and replace it with the new product tagline.

## 2. Hero Buttons
The main page currently features three primary call-to-action buttons (originally linking to Phoenix Guides, Source Code, and Changelog). These should be repurposed for Vici's core actions:

*   **Button 1:** 
    *   **Text:** `Connect your agent`
*   **Button 2:** 
    *   **Text:** `View on GitHub`
*   **Button 3:** 
    *   **Text:** `Create an account` (previously referred to as "Dashboard")
    *   **Link:** This button needs to route users directly to the sign-in / registration page.
    *   **Styling:** Maintain the existing color and styling to keep the layout consistent.

## Future Scope
A full rewrite of the landing page's copy, messaging, and layout will be done in a later pass to clearly communicate Vici's specific use cases. For now, the structure remains "as-is" with only the title and the three button labels/links changing.