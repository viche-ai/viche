defmodule Viche.Auth.EmailTest do
  use ExUnit.Case, async: true

  alias Viche.Auth.Email

  describe "magic_link/2" do
    test "builds an email with the correct fields" do
      url = "https://viche.ai/auth/verify?token=abc"
      email = Email.magic_link("alice@example.com", url)

      assert email.to == [{"", "alice@example.com"}]
      assert email.from == Viche.Config.email_from()
      assert email.subject == "Your Viche login link"
      assert email.text_body =~ url
      assert email.text_body =~ "expires in 15 minutes"
    end
  end
end
