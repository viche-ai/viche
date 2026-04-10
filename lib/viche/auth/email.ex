defmodule Viche.Auth.Email do
  @moduledoc """
  Builds transactional emails for the authentication flow.
  """

  import Swoosh.Email

  @doc """
  Builds a magic link email for the given recipient and URL.
  """
  @spec magic_link(String.t(), String.t()) :: Swoosh.Email.t()
  def magic_link(to_email, url) do
    app_url = Viche.Config.app_url()

    new()
    |> to(to_email)
    |> from(Viche.Config.email_from())
    |> subject("Your Viche login link")
    |> text_body("""
    Hi,

    Click the link below to log in to Viche:

    #{url}

    This link expires in 15 minutes and can only be used once.

    If you did not request this, you can safely ignore this email.
    """)
    |> html_body(magic_link_html(url, app_url, Viche.Config.host()))
  end

  defp magic_link_html(url, app_url, host) do
    ~s"""
    <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
    <html xmlns="http://www.w3.org/1999/xhtml">
    <head>
      <meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1.0" />
      <title>Your Viche login link</title>
    </head>
    <body style="margin:0;padding:0;background-color:#1d2427;font-family:-apple-system,BlinkMacSystemFont,'Inter','Segoe UI',sans-serif;">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#1d2427;">
        <tr>
          <td align="center" style="padding:40px 16px;">
            <table role="presentation" width="480" cellpadding="0" cellspacing="0" border="0" style="max-width:480px;width:100%;background-color:#252e33;border:1px solid #3a4449;border-radius:12px;">
              <!-- Logo -->
              <tr>
                <td style="padding:32px 32px 0 32px;">
                  <table role="presentation" cellpadding="0" cellspacing="0" border="0">
                    <tr>
                      <td style="vertical-align:middle;">
                        <img src="#{app_url}/images/logo.png" alt="Viche" height="32" style="display:block;height:32px;width:auto;" />
                      </td>
                      <td style="vertical-align:middle;padding-left:10px;">
                        <span style="font-size:20px;font-weight:600;color:#d3c6aa;font-family:-apple-system,BlinkMacSystemFont,'Inter','Segoe UI',sans-serif;">Viche</span>
                      </td>
                    </tr>
                  </table>
                </td>
              </tr>
              <!-- Heading -->
              <tr>
                <td style="padding:28px 32px 0 32px;">
                  <h1 style="margin:0;font-size:24px;font-weight:600;color:#d3c6aa;font-family:-apple-system,BlinkMacSystemFont,'Inter','Segoe UI',sans-serif;">Your magic link &#128279;</h1>
                </td>
              </tr>
              <!-- Copy -->
              <tr>
                <td style="padding:16px 32px 0 32px;">
                  <p style="margin:0;font-size:15px;line-height:1.6;color:#d3c6aa;font-family:-apple-system,BlinkMacSystemFont,'Inter','Segoe UI',sans-serif;">Click the button below to sign in to Viche. This link expires in 15 minutes and can only be used once.</p>
                </td>
              </tr>
              <!-- CTA Button -->
              <tr>
                <td align="center" style="padding:28px 32px;">
                  <table role="presentation" cellpadding="0" cellspacing="0" border="0">
                    <tr>
                      <td align="center" style="background-color:#A7C080;border-radius:8px;">
                        <a href="#{url}" target="_blank" style="display:inline-block;padding:14px 32px;font-size:16px;font-weight:600;color:#1a2420;text-decoration:none;font-family:-apple-system,BlinkMacSystemFont,'Inter','Segoe UI',sans-serif;">Sign in to Viche &rarr;</a>
                      </td>
                    </tr>
                  </table>
                </td>
              </tr>
              <!-- Disclaimer -->
              <tr>
                <td style="padding:0 32px 32px 32px;">
                  <p style="margin:0;font-size:13px;line-height:1.5;color:#7a8478;font-family:-apple-system,BlinkMacSystemFont,'Inter','Segoe UI',sans-serif;">If you did not request this, you can safely ignore this email.</p>
                </td>
              </tr>
            </table>
            <!-- Footer -->
            <table role="presentation" width="480" cellpadding="0" cellspacing="0" border="0" style="max-width:480px;width:100%;">
              <tr>
                <td align="center" style="padding:24px 0;">
                  <p style="margin:0;font-size:12px;color:#7a8478;font-family:-apple-system,BlinkMacSystemFont,'Inter','Segoe UI',sans-serif;">&copy; Viche &middot; #{host}</p>
                </td>
              </tr>
            </table>
          </td>
        </tr>
      </table>
    </body>
    </html>
    """
  end
end
