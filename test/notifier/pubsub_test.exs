defmodule Ash.Test.Notifier.PubSubTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Ash.Test.Domain, as: Domain

  defmodule PubSub do
    def broadcast(topic, event, notification) do
      send(
        Application.get_env(__MODULE__, :notifier_test_pid),
        {:broadcast, topic, event, notification}
      )
    end
  end

  defmodule Post do
    @moduledoc false
    use Ash.Resource,
      domain: Domain,
      data_layer: Ash.DataLayer.Ets,
      notifiers: [
        Ash.Notifier.PubSub
      ]

    pub_sub do
      module PubSub
      prefix "post"

      publish :destroy, ["foo", :id]
      publish :update, ["foo", :id], previous_values?: true
      publish :update, ["bar", :name], event: "name_change", previous_values?: true
      publish :update_pkey, ["foo", :_pkey], previous_values?: true

      publish :update_with_transform, ["update_with_transform", :name] do
        transform fn notification ->
          notification.data
        end

        filter fn notification ->
          notification.data.name == "george"
        end
      end

      publish_all :update, ["baz", :id], event: "any_update", except: [:update_pkey]
      publish_all :update, ["fiz", :id], event: "any_update", except: [:doesnotexist]
    end

    ets do
      private?(true)
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        accept :*
      end

      update :update do
        require_atomic? false
        accept :*
      end

      update :update_with_transform do
        require_atomic? false
        accept :*
      end

      update :update_pkey do
        accept :*
        require_atomic? false
      end
    end

    attributes do
      uuid_primary_key :id, writable?: true

      attribute :name, :string do
        public?(true)
      end
    end
  end

  defmodule User do
    @moduledoc false
    use Ash.Resource,
      domain: Domain,
      data_layer: Ash.DataLayer.Ets,
      notifiers: [
        Ash.Notifier.PubSub
      ]

    pub_sub do
      module PubSub
      prefix "users"
      delimiter "."

      publish :create, [:id, "created"]
    end

    ets do
      private?(true)
    end

    actions do
      default_accept :*
      defaults create: :*
    end

    attributes do
      uuid_primary_key :id

      attribute :name, :string do
        public?(true)
      end
    end
  end

  setup do
    Application.put_env(PubSub, :notifier_test_pid, self())

    :ok
  end

  test "publishing a message with a change value" do
    post =
      Post
      |> Ash.Changeset.for_create(:create, %{})
      |> Ash.create!()

    Ash.destroy!(post)

    message = "post:foo:#{post.id}"
    assert_receive {:broadcast, ^message, "destroy", %Ash.Notifier.Notification{}}
  end

  test "from is the pid that sent the message" do
    post =
      Post
      |> Ash.Changeset.for_create(:create, %{})
      |> Ash.create!()

    Ash.destroy!(post)

    message = "post:foo:#{post.id}"
    pid = self()
    assert_receive {:broadcast, ^message, "destroy", %Ash.Notifier.Notification{from: ^pid}}
  end

  test "notification_metadata is included" do
    post =
      Post
      |> Ash.Changeset.for_create(:create, %{})
      |> Ash.create!()

    Ash.destroy!(post, notification_metadata: %{foo: :bar})

    message = "post:foo:#{post.id}"

    assert_receive {:broadcast, ^message, "destroy",
                    %Ash.Notifier.Notification{metadata: %{foo: :bar}}}
  end

  test "publishing with a filter and a transform" do
    post =
      Post
      |> Ash.Changeset.for_create(:create, %{name: "ted"})
      |> Ash.create!()

    post
    |> Ash.Changeset.for_update(:update_with_transform, %{name: "george"})
    |> Ash.update!()

    post
    |> Ash.Changeset.for_update(:update_with_transform, %{name: "fred"})
    |> Ash.update!()

    assert_receive {
      :broadcast,
      "post:update_with_transform:george",
      "update_with_transform",
      %Post{}
    }

    refute_receive {
      :broadcast,
      "post:update_with_transform:fred",
      "update_with_transform",
      %Post{}
    }
  end

  test "publishing a message with multiple matches/changes" do
    post =
      Post
      |> Ash.Changeset.for_create(:create, %{name: "ted"})
      |> Ash.create!()

    post
    |> Ash.Changeset.for_update(:update, %{name: "joe"})
    |> Ash.update!()

    message = "post:foo:#{post.id}"
    assert_receive {:broadcast, ^message, "update", %Ash.Notifier.Notification{}}

    message = "post:bar:joe"
    assert_receive {:broadcast, ^message, "name_change", %Ash.Notifier.Notification{}}
    message = "post:bar:ted"
    assert_receive {:broadcast, ^message, "name_change", %Ash.Notifier.Notification{}}
    message = "post:baz:#{post.id}"
    assert_receive {:broadcast, ^message, "any_update", %Ash.Notifier.Notification{}}
    message = "post:fiz:#{post.id}"
    assert_receive {:broadcast, ^message, "any_update", %Ash.Notifier.Notification{}}
  end

  test "publishing a message with a pkey matcher" do
    post =
      Post
      |> Ash.Changeset.for_create(:create, %{name: "ted"})
      |> Ash.create!()

    new_id = Ash.UUID.generate()

    post
    |> Ash.Changeset.for_update(:update, %{id: new_id})
    |> Ash.update!(action: :update_pkey)

    message = "post:foo:#{post.id}"
    assert_receive {:broadcast, ^message, "update_pkey", %Ash.Notifier.Notification{}}

    message = "post:foo:#{new_id}"
    assert_receive {:broadcast, ^message, "update_pkey", %Ash.Notifier.Notification{}}
    message = "post:baz:#{new_id}"
    refute_receive {:broadcast, ^message, "any_update", %Ash.Notifier.Notification{}}
    message = "post:fiz:#{new_id}"
    assert_receive {:broadcast, ^message, "any_update", %Ash.Notifier.Notification{}}
  end

  test "publishing a message with a different delimiter" do
    user =
      User
      |> Ash.Changeset.for_create(:create, %{name: "Dave"})
      |> Ash.create!()

    message = "users.#{user.id}.created"
    assert_receive {:broadcast, ^message, "create", %Ash.Notifier.Notification{}}
  end
end
