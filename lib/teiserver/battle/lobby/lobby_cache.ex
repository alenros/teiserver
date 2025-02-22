defmodule Teiserver.Battle.LobbyCache do
  alias Phoenix.PubSub
  alias Teiserver.Coordinator
  import Central.Helpers.NumberHelper, only: [int_parse: 1]
  alias Teiserver.Battle.Lobby
  alias Teiserver.Data.Types, as: T
  require Logger

  @spec get_lobby(T.lobby_id()) :: T.lobby() | nil
  def get_lobby(id) do
    call_lobby(int_parse(id), :get_lobby_state)
  end

  @spec get_lobby_match_uuid(T.lobby_id()) :: String.t() | nil
  def get_lobby_match_uuid(lobby_id) do
    call_lobby(lobby_id, :get_match_uuid)
  end

  @spec get_combined_lobby_state(T.lobby_id()) :: map() | nil
  def get_combined_lobby_state(lobby_id) do
    call_lobby(lobby_id, :get_combined_state)
  end

  @spec get_lobby_server_uuid(T.lobby_id()) :: String.t() | nil
  def get_lobby_server_uuid(lobby_id) do
    call_lobby(lobby_id, :get_server_uuid)
  end

  @spec get_lobby_by_match_uuid(String.t()) :: T.lobby() | nil
  def get_lobby_by_match_uuid(uuid) do
    lobby_list = list_lobby_ids()
      |> Stream.map(fn lobby_id -> {lobby_id, get_lobby_match_uuid(lobby_id)} end)
      |> Stream.filter(fn {_lobby_id, lobby_uuid} -> lobby_uuid == uuid end)
      |> Enum.take(1)
      |> Enum.map(fn {lobby_id, _lobby_uuid} -> get_lobby(lobby_id) end)

    case lobby_list do
      [] -> nil
      [lobby | _] -> lobby
    end
  end

  @spec get_lobby_by_server_uuid(String.t()) :: T.lobby() | nil
  def get_lobby_by_server_uuid(uuid) do
    lobby_list = list_lobby_ids()
      |> Stream.map(fn lobby_id -> {lobby_id, get_lobby_server_uuid(lobby_id)} end)
      |> Stream.filter(fn {_lobby_id, server_uuid} -> server_uuid == uuid end)
      |> Enum.take(1)
      |> Enum.map(fn {lobby_id, _server_uuid} -> get_lobby(lobby_id) end)

    case lobby_list do
      [] -> nil
      [lobby | _] -> lobby
    end
  end

  @spec list_lobby_ids :: [T.lobby_id()]
  def list_lobby_ids() do
    Horde.Registry.select(Teiserver.LobbyRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @spec list_lobbies() :: [T.lobby()]
  def list_lobbies() do
    list_lobby_ids()
      |> Enum.map(fn lobby_id -> get_lobby(lobby_id) end)
      |> Enum.filter(fn lobby -> lobby != nil end)
  end

  @spec update_lobby_values(T.lobby_id(), map()) :: :ok | nil
  def update_lobby_values(lobby_id, new_values) do
    cast_lobby(lobby_id, {:update_values, new_values})
  end

  @spec set_lobby_password(T.lobby_id(), String.t() | nil) :: :ok | nil
  def set_lobby_password(lobby_id, password) do
    cast_lobby(lobby_id, {:set_password, password})
  end

  @spec update_lobby(T.lobby(), nil | atom, any) :: T.lobby()
  def update_lobby(%{id: lobby_id} = lobby, nil, :silent) do
    Logger.warn("update_lobby is still being called for :silent")
    cast_lobby(lobby_id, {:update_lobby, lobby})

    lobby
  end

  def update_lobby(%{id: lobby_id} = lobby, nil, reason) do
    Logger.warn("update_lobby is still being called, reason: #{reason}")
    cast_lobby(lobby_id, {:update_lobby, lobby})

    PubSub.broadcast(
      Central.PubSub,
      "teiserver_lobby_updates:#{lobby.id}",
      {:lobby_update, :updated, lobby.id, reason}
    )

    lobby
  end

  def update_lobby(%{id: lobby_id} = lobby, data, reason) do
    Logger.warn("update_lobby is still being called, reason: #{reason}")
    cast_lobby(lobby_id, {:update_lobby, lobby})

    if Enum.member?([:update_battle_info], reason) do
      PubSub.broadcast(
        Central.PubSub,
        "legacy_all_battle_updates",
        {:global_battle_updated, lobby.id, reason}
      )

      PubSub.broadcast(
        Central.PubSub,
        "teiserver_global_lobby_updates",
        %{
          channel: "teiserver_global_lobby_updates",
          event: :updated_values,
          new_values: data
        }
      )
    else
      PubSub.broadcast(
        Central.PubSub,
        "legacy_battle_updates:#{lobby.id}",
        {:battle_updated, lobby.id, data, reason}
      )
    end

    PubSub.broadcast(
      Central.PubSub,
      "teiserver_lobby_updates:#{lobby.id}",
      {:lobby_update, :updated, lobby.id, reason}
    )

    lobby
  end

  # Start areas
  @spec add_start_rectangle(T.lobby_id(), non_neg_integer(), list()) :: :ok | nil
  def add_start_rectangle(lobby_id, area_id, [a, b, c, d]) do
    area_id = int_parse(area_id)
    cast_lobby(lobby_id, {:add_start_area, area_id, %{
      shape: "rectangle",
      x1: a,
      y1: b,
      x2: c,
      y2: d
    }})
  end

  @spec add_start_area(T.lobby_id(), non_neg_integer(), list()) :: :ok | nil
  def add_start_area(lobby_id, area_id, definition) do
    area_id = int_parse(area_id)
    cast_lobby(lobby_id, {:add_start_area, area_id, definition})
  end

  @spec remove_start_area(T.lobby_id(), non_neg_integer()) :: :ok | nil
  def remove_start_area(lobby_id, area_id) do
    area_id = int_parse(area_id)
    cast_lobby(lobby_id, {:remove_start_area, area_id})
  end

  # Enabled/Disabled units
  @spec enable_all_units(T.lobby_id()) :: :ok | nil
  def enable_all_units(lobby_id) when is_integer(lobby_id) do
    cast_lobby(lobby_id, :enable_all_units)
  end

  @spec enable_units(T.lobby_id(), [String.t()]) :: :ok | nil
  def enable_units(lobby_id, units) when is_integer(lobby_id) and is_list(units) do
    cast_lobby(lobby_id, {:enable_units, units})
  end

  @spec disable_units(T.lobby_id(), [String.t()]) :: :ok | nil
  def disable_units(lobby_id, units) when is_integer(lobby_id) and is_list(units) do
    cast_lobby(lobby_id, {:disable_units, units})
  end

  # Bots
  @spec get_bots(T.lobby_id()) :: map() | nil
  def get_bots(lobby_id) do
    call_lobby(lobby_id, :get_bots)
  end

  @spec add_bot_to_lobby(T.lobby_id(), map()) :: :ok | nil
  def add_bot_to_lobby(lobby_id, bot), do: cast_lobby(lobby_id, {:add_bot, bot})

  @spec update_bot(T.lobby_id(), String.t(), map()) :: nil | :ok
  def update_bot(lobby_id, bot_name, "0"), do: remove_bot(lobby_id, bot_name)

  def update_bot(lobby_id, bot_name, new_data), do: cast_lobby(lobby_id, {:update_bot, bot_name, new_data})

  @spec remove_bot(T.lobby_id(), String.t()) :: :ok | nil
  def remove_bot(lobby_id, bot_name), do: cast_lobby(lobby_id, {:remove_bot, bot_name})

  # Modoptions
  @spec get_modoptions(T.lobby_id()) :: map() | nil
  def get_modoptions(lobby_id), do: call_lobby(lobby_id, :get_modoptions)

  @spec set_modoption(T.lobby_id(), String.t(), String.t()) :: :ok | nil
  def set_modoption(lobby_id, key, value), do: cast_lobby(lobby_id, {:set_modoption, key, value})

  @spec set_modoptions(T.lobby_id(), map()) :: :ok | nil
  def set_modoptions(lobby_id, options), do: cast_lobby(lobby_id, {:set_modoptions, options})

  @spec remove_modoptions(T.lobby_id(), [String.t()]) :: :ok | nil
  def remove_modoptions(lobby_id, keys), do: cast_lobby(lobby_id, {:remove_modoptions, keys})

  # Membership
  @spec add_user_to_lobby(T.userid(), T.lobby_id(), String.t()) :: nil | :ok
  def add_user_to_lobby(userid, lobby_id, script_password) do
    cast_lobby(lobby_id, {:add_user, userid, script_password})
  end

  @spec remove_user_from_lobby(T.userid(), T.lobby_id()) :: nil | :ok
  def remove_user_from_lobby(userid, lobby_id) do
    cast_lobby(lobby_id, {:remove_user, userid})
  end

  @spec get_lobby_member_list(T.lobby_id()) :: [T.userid()] | nil
  def get_lobby_member_list(lobby_id) do
    call_lobby(lobby_id, :get_member_list)
  end

  @spec get_lobby_member_count(T.lobby_id()) :: integer() | :lobby
  def get_lobby_member_count(lobby_id) do
    call_lobby(lobby_id, :get_member_count)
  end

  @spec get_lobby_spectator_count(T.lobby_id()) :: integer()
  def get_lobby_spectator_count(lobby_id) do
    call_lobby(lobby_id, :get_spectator_count)
  end

  @spec get_lobby_player_count(T.lobby_id()) :: integer() | :lobby
  def get_lobby_player_count(lobby_id) do
    call_lobby(lobby_id, :get_player_count)
  end

  @spec list_lobby_players(T.lobby_id()) :: [T.client()] | nil
  def list_lobby_players(lobby_id) do
    call_lobby(lobby_id, :get_player_list)
  end

  @spec list_lobby_players!(T.lobby_id()) :: [T.client()]
  def list_lobby_players!(id) do
    get_lobby(id).players
  end

  @spec add_lobby(T.lobby()) :: T.lobby()
  def add_lobby(%{founder_id: _} = lobby) do
    Lobby.start_battle_lobby_throttle(lobby.id)
    start_lobby_server(lobby)

    _consul_pid = Coordinator.start_consul(lobby.id)
    _balance_pid = Coordinator.start_balancer(lobby.id)

    :ok = PubSub.broadcast(
      Central.PubSub,
      "legacy_all_battle_updates",
      {:global_battle_updated, lobby.id, :battle_opened}
    )

    :ok = PubSub.broadcast(
      Central.PubSub,
      "teiserver_global_lobby_updates",
      %{
        channel: "teiserver_global_lobby_updates",
        event: :opened,
        lobby: lobby
      }
    )

    lobby
  end

  @spec start_lobby_server(T.lobby()) :: pid()
  def start_lobby_server(lobby) do
    {:ok, server_pid} =
      DynamicSupervisor.start_child(Teiserver.LobbySupervisor, {
        Teiserver.Battle.LobbyServer,
        name: "lobby_#{lobby.id}",
        data: %{
          lobby: lobby
        }
      })

    server_pid
  end

  @spec lobby_exists?(T.lobby_id()) :: boolean()
  def lobby_exists?(lobby_id) when is_integer(lobby_id) do
    case get_lobby_pid(lobby_id) do
      nil -> false
      _ -> true
    end
  end

  @spec get_lobby_pid(T.lobby_id()) :: pid() | nil
  def get_lobby_pid(lobby_id) when is_integer(lobby_id) do
    case Horde.Registry.lookup(Teiserver.LobbyRegistry, lobby_id) do
      [{pid, _}] -> pid
      _ -> nil
    end
  end

  @doc """
  GenServer.cast the message to the LobbyServer process for lobby_id
  """
  @spec cast_lobby(T.lobby_id(), any) :: :ok | nil
  def cast_lobby(lobby_id, message) when is_integer(lobby_id) do
    case get_lobby_pid(lobby_id) do
      nil -> nil
      pid ->
        GenServer.cast(pid, message)
        :ok
    end
  end

  @doc """
  GenServer.call the message to the LobbyServer process for lobby_id and return the result
  """
  @spec call_lobby(T.lobby_id(), any) :: any | nil
  def call_lobby(lobby_id, message) when is_integer(lobby_id) do
    case get_lobby_pid(lobby_id) do
      nil -> nil
      pid ->
        try do
          GenServer.call(pid, message)

          # If the process has somehow died, we just return nil
        catch
          :exit, _ ->
            nil
        end
    end
  end

  @spec stop_lobby_server(T.lobby_id()) :: :ok | nil
  def stop_lobby_server(lobby_id) when is_integer(lobby_id) do
    case get_lobby_pid(lobby_id) do
      nil -> nil
      p ->
        DynamicSupervisor.terminate_child(Teiserver.LobbySupervisor, p)
        :ok
    end
  end

  @spec close_lobby(integer() | nil, atom) :: :ok
  def close_lobby(lobby_id, reason \\ :closed) when is_integer(lobby_id) do
    battle = get_lobby(lobby_id)
    Coordinator.close_lobby(lobby_id)

    # Kill lobby server process
    stop_lobby_server(lobby_id)

    [battle.founder_id | battle.players]
    |> Enum.each(fn userid ->
      PubSub.broadcast(
        Central.PubSub,
        "legacy_battle_updates:#{lobby_id}",
        {:remove_user_from_battle, userid, lobby_id}
      )
    end)

    PubSub.broadcast(
      Central.PubSub,
      "legacy_all_battle_updates",
      {:global_battle_updated, lobby_id, :battle_closed}
    )

    :ok = PubSub.broadcast(
      Central.PubSub,
      "teiserver_global_lobby_updates",
      %{
        channel: "teiserver_global_lobby_updates",
        event: :closed,
        lobby_id: lobby_id
      }
    )


    :ok = PubSub.broadcast(
      Central.PubSub,
      "teiserver_lobby_updates:#{battle.id}",
      {:lobby_update, :closed, battle.id, reason}
    )

    Lobby.stop_battle_lobby_throttle(lobby_id)
  end

  # Balance related
  @spec get_lobby_current_balance(T.lobby_id()) :: map() | nil
  def get_lobby_current_balance(lobby_id) do
    Coordinator.call_balancer(lobby_id, :get_current_balance)
  end

  @spec get_lobby_balance_mode(T.lobby_id()) :: :solo | :grouped
  def get_lobby_balance_mode(lobby_id) do
    Coordinator.call_balancer(lobby_id, :get_balance_mode)
  end
end
