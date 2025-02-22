defmodule Teiserver.Chat.RoomMessage do
  use CentralWeb, :schema

  schema "teiserver_room_messages" do
    field :content, :string
    field :chat_room, :string
    field :inserted_at, :utc_datetime
    belongs_to :user, Central.Account.User
  end

  @doc """
  Builds a changeset based on the `struct` and `params`.
  """
  @spec changeset(Map.t(), Map.t()) :: Ecto.Changeset.t()
  def changeset(struct, params \\ %{}) do
    params = params
    |> trim_strings([:content, :chat_room])

    struct
    |> cast(params, [:content, :chat_room, :inserted_at, :user_id])
    |> validate_required([:content, :chat_room, :inserted_at, :user_id])
  end

  @spec authorize(Atom.t(), Plug.Conn.t(), Map.t()) :: Boolean.t()
  def authorize(_, conn, _), do: allow?(conn, "chat")
end
