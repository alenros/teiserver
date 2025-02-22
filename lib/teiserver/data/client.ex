# defmodule Teiserver.Data.ClientStruct do
#   @enforce_keys [:in_game, :away, :rank, :moderator, :bot]
#   defstruct [
#     :id, :name, :team_size, :icon, :colour, :settings, :conditions, :map_list,
#     current_search_time: 0, current_size: 0, contents: [], pid: nil
#   ]
# end

defmodule Teiserver.Client do
  @moduledoc false
  alias Phoenix.PubSub
  alias Teiserver.{Room, User, Account, Telemetry, Clans}
  alias Teiserver.Battle.Lobby
  alias Teiserver.Account.ClientLib
  # alias Central.Helpers.TimexHelper
  require Logger

  alias Teiserver.Data.Types, as: T

  # @chat_flood_count_short 3
  # @chat_flood_time_short 1
  # @chat_flood_count_long 10
  # @chat_flood_time_long 5
  # @temp_mute_count_limit 3

  @spec create(Map.t()) :: Map.t()
  def create(client) do
    Map.merge(
      %{
        in_game: false,
        away: false,
        rank: 1,
        moderator: false,
        bot: false,

        # Battle stuff
        ready: false,
        unready_at: nil,
        readyup_history: [],
        player_number: 0,# In spring this is team_number
        team_colour: "0",
        team_number: 0, # In spring this would be ally_team_number
        player: false,
        handicap: 0,
        sync: %{
          engine: 0,
          game: 0,
          map: 0
        },
        side: 0,
        role: "spectator",

        # TODO: Change client:lobby_id to be client:battle_lobby_id
        lobby_id: nil,
        print_client_messages: false,
        print_server_messages: false,
        chat_times: [],
        temp_mute_count: 0,
        ip: nil,
        country: nil,
        lobby_client: nil,

        shadowbanned: false,
        awaiting_warn_ack: false,
        warned: false,
        muted: false,
        restricted: false,
        lobby_host: false,
        party_id: nil,
        clan_tag: nil
      },
      client
    )
  end

  @spec reset_battlestatus(Map.t()) :: Map.t()
  def reset_battlestatus(client) do
    %{client |
      player_number: 0,
      team_number: 0,
      player: false,
      handicap: 0,
      sync: %{
          engine: 0,
          game: 0,
          map: 0
        },
      role: "spectator",
      lobby_id: nil
    }
  end

  @spec login(T.user(), String.t() | nil) :: T.client()
  def login(user, ip \\ nil) do
    stats = Account.get_user_stat_data(user.id)

    clan_tag = case Clans.get_clan(user.clan_id) do
      nil -> nil
      clan -> clan.tag
    end

    client =
      create(%{
        userid: user.id,
        name: user.name,
        tcp_pid: self(),
        rank: user.rank,
        moderator: User.is_moderator?(user),
        bot: User.is_bot?(user),
        away: false,
        in_game: false,
        ip: ip || stats["last_ip"],
        country: stats["country"] || "??",
        lobby_client: stats["lobby_client"],

        shadowbanned: User.is_shadowbanned?(user),
        muted: User.has_mute?(user),
        awaiting_warn_ack: false,
        warned: false,

        clan_tag: clan_tag
      })

    ClientLib.start_client_server(client)

    PubSub.broadcast(
      Central.PubSub,
      "legacy_all_user_updates",
      {:user_logged_in, user.id}
    )

    PubSub.broadcast(
      Central.PubSub,
      "teiserver_client_inout",
      {:client_inout, :login, user.id}
    )

    PubSub.broadcast(
      Central.PubSub,
      "teiserver_client_messages:#{user.id}",
      %{
        channel: "teiserver_client_messages:#{user.id}",
        event: :connected
      }
    )

    PubSub.broadcast(
      Central.PubSub,
      "teiserver_client_action_updates:#{user.id}",
      {:client_action, :client_connect, user.id}
    )

    # Message logging
    if user.print_client_messages do
      enable_client_message_print(user.id)
    end

    if user.print_server_messages do
      enable_server_message_print(user.id)
    end

    # Lets give everything a chance to propagate
    :timer.sleep(Application.get_env(:central, Teiserver)[:post_login_delay])

    Logger.info("Client connected: #{client.name} using #{client.lobby_client}")

    if client.bot do
      Telemetry.increment(:bots_connected)
    else
      Telemetry.increment(:users_connected)
    end

    client
  end

  @spec get_client_by_name(nil) :: nil
  @spec get_client_by_name(String.t()) :: nil | T.client()
  defdelegate get_client_by_name(name), to: ClientLib

  @spec get_client_by_id(nil) :: nil
  @spec get_client_by_id(T.userid()) :: nil | T.client()
  defdelegate get_client_by_id(userid), to: ClientLib

  @spec get_clients([T.userid()]) :: List.t()
  defdelegate get_clients(id_list), to: ClientLib

  @spec list_client_ids() :: [T.userid()]
  defdelegate list_client_ids(), to: ClientLib

  @spec list_clients() :: [T.client()]
  defdelegate list_clients(), to: ClientLib

  @spec list_clients([T.userid()]) :: [T.client()]
  defdelegate list_clients(id_list), to: ClientLib

  @spec update(Map.t(), :silent | :client_updated_status | :client_updated_battlestatus) :: T.client()
  def update(client, reason), do: ClientLib.replace_update_client(client, reason)


  @spec get_client_pid(T.userid()) :: pid() | nil
  defdelegate get_client_pid(userid), to: ClientLib

  @spec cast_client(T.userid(), any) :: any
  defdelegate cast_client(userid, msg), to: ClientLib

  @spec call_client(T.userid(), any) :: any | nil
  defdelegate call_client(userid, msg), to: ClientLib



  @spec join_battle(T.client_id(), Integer.t(), boolean()) :: nil | T.client()
  def join_battle(userid, lobby_id, lobby_host) do
    case get_client_by_id(userid) do
      nil ->
        nil

      client ->
        new_client = reset_battlestatus(client)
        new_client = %{new_client |
          lobby_id: lobby_id,
          lobby_host: lobby_host
        }
        ClientLib.replace_update_client(new_client, :silent)
        new_client
    end
  end

  @spec leave_battle(Integer.t() | nil) :: Map.t() | nil
  def leave_battle(nil), do: nil

  def leave_battle(userid) do
    case get_client_by_id(userid) do
      nil ->
        nil

      %{lobby_id: nil} = client ->
        client

      client ->
        new_client = reset_battlestatus(client)
        ClientLib.replace_update_client(new_client, :silent)
        new_client
    end
  end

  @spec leave_rooms(Integer.t()) :: List.t()
  def leave_rooms(userid) do
    Room.list_rooms()
    |> Enum.each(fn room ->
      if userid in room.members do
        Room.remove_user_from_room(userid, room.name)
      end
    end)
  end

  @spec disconnect(T.userid(), nil | String.t()) :: nil | :ok | {:error, any}
  def disconnect(userid, reason \\ nil) do
    case get_client_by_id(userid) do
      nil -> nil
      client -> do_disconnect(client, reason)
    end
  end

  # If it's a test user, don't worry about actually disconnecting it
  defp do_disconnect(client, reason) do
    Logger.info("#{client.name}/##{client.userid} disconnected because #{reason}")
    Lobby.remove_user_from_any_lobby(client.userid)
    Room.remove_user_from_any_room(client.userid)
    leave_rooms(client.userid)

    # If they are part of a party, lets leave it
    Account.leave_party(client.party_id, client.userid)

    if client.bot do
      Telemetry.increment(:bots_disconnected)
    else
      Telemetry.increment(:users_disconnected)
    end

    # Kill lobby server process
    ClientLib.stop_client_server(client.userid)

    # Typically we would only send the username but it is possible they just changed their username
    # and as such we need to tell the system what username is logging out
    PubSub.broadcast(
      Central.PubSub,
      "legacy_all_user_updates",
      {:user_logged_out, client.userid, client.name}
    )

    PubSub.broadcast(
      Central.PubSub,
      "teiserver_client_action_updates:#{client.userid}",
      {:client_action, :client_disconnect, client.userid}
    )

    PubSub.broadcast(
      Central.PubSub,
      "teiserver_client_inout",
      {:client_inout, :disconnect, client.userid, reason}
    )

    PubSub.broadcast(
      Central.PubSub,
      "teiserver_client_messages:#{client.userid}",
      %{
        channel: "teiserver_client_messages:#{client.userid}",
        event: :disconnected
      }
    )
  end

  @spec shadowban_client(T.userid()) :: :ok
  def shadowban_client(userid) do
    client = get_client_by_id(userid)
    update(%{client | shadowbanned: true}, :silent)
    :ok
  end

  @spec set_awaiting_warn_ack(T.userid()) :: :ok
  def set_awaiting_warn_ack(userid) do
    case get_client_by_id(userid) do
      nil ->
        :ok
      client ->
        update(%{client | awaiting_warn_ack: true}, :silent)
    end
    :ok
  end

  @spec clear_awaiting_warn_ack(T.userid()) :: :ok
  def clear_awaiting_warn_ack(userid) do
    client = get_client_by_id(userid)
    update(%{client | awaiting_warn_ack: false}, :silent)
    :ok
  end

  @spec enable_client_message_print(T.userid()) :: :ok
  def enable_client_message_print(userid) do
    case get_client_by_id(userid) do
      nil -> :ok
      client ->
        send(client.tcp_pid, {:put, :print_client_messages, true})
        :ok
    end
  end

  @spec disable_client_message_print(T.userid()) :: :ok
  def disable_client_message_print(userid) do
    case get_client_by_id(userid) do
      nil -> :ok
      client ->
        send(client.tcp_pid, {:put, :print_client_messages, false})
        :ok
    end
  end

  @spec enable_server_message_print(T.userid()) :: :ok
  def enable_server_message_print(userid) do
    case get_client_by_id(userid) do
      nil -> :ok
      client ->
        send(client.tcp_pid, {:put, :print_server_messages, true})
        :ok
    end
  end

  @spec disable_server_message_print(T.userid()) :: :ok
  def disable_server_message_print(userid) do
    case get_client_by_id(userid) do
      nil -> :ok
      client ->
        send(client.tcp_pid, {:put, :print_server_messages, false})
        :ok
    end
  end
end
