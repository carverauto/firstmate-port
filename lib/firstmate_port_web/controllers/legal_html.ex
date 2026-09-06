defmodule FirstmatePortWeb.LegalHTML do
  @moduledoc "Templates for the public terms and privacy pages."

  use FirstmatePortWeb, :html

  embed_templates "legal_html/*"

  @doc """
  Renders the operator's contact route, or an honest placeholder when the
  deployment has not configured one.
  """
  attr :email, :string, default: nil
  attr :operator, :string, required: true

  def contact(assigns) do
    ~H"""
    <p :if={@email}>
      Write to <a href={"mailto:#{@email}"}>{@email}</a>.
    </p>
    <p :if={is_nil(@email)}>
      This instance has not published a contact address. Reach {@operator} through
      whichever channel you use to reach your crew.
    </p>
    """
  end

  @doc "The 'last updated' line every policy page carries."
  attr :updated_on, Date, required: true

  def updated(assigns) do
    ~H"""
    <p class="legal-updated">Last updated {Calendar.strftime(@updated_on, "%-d %B %Y")}</p>
    """
  end
end
