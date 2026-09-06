defmodule FirstmatePort.PortalEvidence do
  @moduledoc "Exports actual LiveView renders for optional visual test review."

  def save(name, html) do
    if directory = System.get_env("FIRSTMATE_PORTAL_EVIDENCE_DIR") do
      css = File.read!("priv/static/assets/css/app.css")

      css =
        Enum.reduce(["geist-sans", "geist-mono"], css, fn font, css ->
          data = Base.encode64(File.read!("priv/static/fonts/#{font}.woff2"))
          String.replace(css, "/fonts/#{font}.woff2", "data:font/woff2;base64," <> data)
        end)

      html =
        Enum.reduce(["steering-wheel-black", "steering-wheel-white"], html, fn name, html ->
          data = Base.encode64(File.read!("priv/static/images/#{name}.svg"))
          String.replace(html, "/images/#{name}.svg", "data:image/svg+xml;base64," <> data)
        end)

      File.mkdir_p!(directory)

      File.write!(Path.join(directory, name <> ".html"), """
      <!doctype html><html data-theme="light"><head><meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1">
      <style>#{css}</style></head><body>#{html}</body></html>
      """)
    end
  end
end
