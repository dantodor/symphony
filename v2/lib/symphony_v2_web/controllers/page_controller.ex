defmodule SymphonyV2Web.PageController do
  use SymphonyV2Web, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
