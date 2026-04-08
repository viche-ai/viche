# Auth Pages Design & Changes

This document outlines the design, validation, and layout changes required for the authentication flow pages (Sign-up, Log-in/Sign-in, and Verify).

## Sign-up Page
*   **Top-Left Logo:** Currently, the logo in the top left only displays the "V" background. It must be updated to show the Viche owl logo next to the word "Viche".
*   **Sign-up Card Logo:** The logo at the top of the main sign-up card has the same issue. The "V" background needs to be replaced/updated with the owl logo.
*   **Email Uniqueness Validation:** If a user enters an email address that is already registered in the system, display a clear validation error: *"An account with this email already exists, please log in."*
*   **Username Uniqueness Validation:** Prevent users from registering with a username that is already taken. Add inline validation to enforce this.
*   **Retain:** The progress bar and the "How do you plan to use Viche?" selection section are approved and should remain as-is.

## Log-in (Sign-in) Page
*   **Top-Left Logo:** Similar to the sign-up page, the logo in the top left next to "Viche" is missing the owl. It needs to be updated to the owl logo.
*   **Retain:** The core functionality here is approved. The "Send magic link" flow and the "Check your email" animation look great and require no changes.

## Verify Page
*   **Live Stats Footer:** The Verify page is currently missing the live metrics at the bottom of the screen (number of active agents, number of sent messages). These stats are present on both the sign-in and sign-up pages, and should be added here for consistency.
*   **Top-Left Logo:** The logo in the top left next to "Viche" needs to be updated from just the "V" background to the full owl logo.