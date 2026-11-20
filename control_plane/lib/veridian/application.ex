defmodule Veridian.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # Only the test environment has a database configured so far; starting the
    # Repo without one would crash `iex -S mix` in dev.
    children = if Application.get_env(:veridian, Veridian.Repo), do: [Veridian.Repo], else: []
    Supervisor.start_link(children, strategy: :one_for_one, name: Veridian.Supervisor)
  end
end
