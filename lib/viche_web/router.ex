defmodule VicheWeb.Router do
  use VicheWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {VicheWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", VicheWeb do
    pipe_through :api

    get "/health", HealthController, :check
  end

  scope "/auth", VicheWeb do
    pipe_through :browser

    post "/login", AuthController, :login
    get "/confirm", AuthController, :confirm
    delete "/logout", AuthController, :logout
  end

  scope "/", VicheWeb do
    pipe_through :browser

    live "/", LandingLive
    live "/login", LoginLive
    live "/signup", SignupLive
    live "/verify", VerifyLive
    live "/dashboard", DashboardLive
    live "/agents", AgentsLive
    live "/agents/:id", AgentDetailLive
    live "/sessions", SessionsLive
    live "/network", NetworkLive
    live "/demo", DemoLive
    live "/join", JoinLive
    live "/settings", SettingsLive
  end

  scope "/.well-known", VicheWeb do
    pipe_through :api

    get "/agent-registry", WellKnownController, :agent_registry
  end

  scope "/registry", VicheWeb do
    pipe_through :api

    post "/register", RegistryController, :register
    get "/discover", RegistryController, :discover
  end

  scope "/messages", VicheWeb do
    pipe_through :api

    post "/:agent_id", MessageController, :send_message
  end

  scope "/inbox", VicheWeb do
    pipe_through :api

    get "/:agent_id", InboxController, :read_inbox
  end

  scope "/agents", VicheWeb do
    pipe_through :api

    post "/:agent_id/heartbeat", HeartbeatController, :heartbeat
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:viche, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: VicheWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
