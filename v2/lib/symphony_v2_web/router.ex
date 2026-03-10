defmodule SymphonyV2Web.Router do
  use SymphonyV2Web, :router

  import SymphonyV2Web.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SymphonyV2Web.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:symphony_v2, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: SymphonyV2Web.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", SymphonyV2Web do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    get "/users/register", UserRegistrationController, :new
    post "/users/register", UserRegistrationController, :create
  end

  scope "/", SymphonyV2Web do
    pipe_through [:browser]

    get "/users/log-in", UserSessionController, :new
    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  ## Authenticated routes — all app routes require login

  scope "/", SymphonyV2Web do
    pipe_through [:browser, :require_authenticated_user]

    get "/", PageController, :home

    get "/users/settings", UserSettingsController, :edit
    put "/users/settings", UserSettingsController, :update
  end

  ## Authenticated LiveView routes

  live_session :authenticated,
    on_mount: {SymphonyV2Web.UserAuth, :ensure_authenticated} do
    scope "/", SymphonyV2Web do
      pipe_through [:browser]

      live "/tasks", TaskLive.Index, :index
      live "/tasks/new", TaskLive.New, :new
      live "/tasks/:id", TaskLive.Show, :show
    end
  end
end
