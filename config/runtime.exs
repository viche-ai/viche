import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/viche start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :viche, VicheWeb.Endpoint, server: true
end

config :viche, VicheWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

config :viche, require_auth: System.get_env("REQUIRE_AUTH") == "true"

# ---------------------------------------------------------------------------
# Email provider (all envs except test, which uses Swoosh.Adapters.Test)
# ---------------------------------------------------------------------------
if config_env() != :test do
  case System.get_env("EMAIL_PROVIDER") do
    "resend" ->
      config :viche, Viche.Mailer,
        adapter: Swoosh.Adapters.Resend,
        api_key: System.get_env("RESEND_API_KEY")

      config :swoosh, :api_client, Swoosh.ApiClient.Req

    "console" ->
      config :viche, Viche.Mailer, adapter: Swoosh.Adapters.Logger

    _ ->
      config :viche, Viche.Mailer, adapter: Swoosh.Adapters.Local
  end
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :viche, Viche.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :viche, :app_url, "https://#{host}"
  config :viche, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Simple Analytics: enabled by default in prod. Set VICHE_ANALYTICS=false to disable.
  config :viche,
    simple_analytics_enabled: System.get_env("VICHE_ANALYTICS") not in ~w(false 0)

  # Telemetry: enabled by default. Set VICHE_TELEMETRY=false to opt out of sending
  # anonymized usage stats to viche.ai.
  config :viche,
    telemetry_enabled: System.get_env("VICHE_TELEMETRY") not in ~w(false 0)

  # Public mode hides the registry selector and locks the UI to the global registry.
  # Intended for self-hosted deployments. Set VICHE_PUBLIC_MODE=true to enable.
  public_mode = System.get_env("VICHE_PUBLIC_MODE") in ~w(true 1)
  config :viche, :public_mode, public_mode

  # Email sender: parse EMAIL_FROM env var as "Name <addr>" or plain address.
  case System.get_env("EMAIL_FROM") do
    nil ->
      config :viche, :email_from, {"Viche", "noreply@#{host}"}

    from_str ->
      case Regex.run(~r/^(.+?)\s*<(.+?)>$/, from_str) do
        [_, name, addr] -> config :viche, :email_from, {String.trim(name), String.trim(addr)}
        _ -> config :viche, :email_from, {"Viche", String.trim(from_str)}
      end
  end

  config :viche, VicheWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :viche, VicheWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :viche, VicheWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :viche, Viche.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
