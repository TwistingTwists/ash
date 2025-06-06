defmodule Ash.Error.Query.NoSuchField do
  @moduledoc "Used when a field(attribute, calculation, aggregate or relationship) that doesn't exist is used in a query"

  use Splode.Error, fields: [:resource, :field], class: :invalid

  def message(error) do
    "No such field #{error.field} for resource #{inspect(error.resource)}"
  end
end
