defmodule FirstmatePort.Fleet.Embeddings.Client do
  @moduledoc """
  How the portal talks to an embedding provider.

  One callback, so a test can hand `FirstmatePort.Fleet.Embeddings` a stub
  instead of a network, and so the provider library stays behind a seam this
  codebase owns. `Embeddings` also accepts a plain three-argument function with
  the same contract, which is all a test usually needs.
  """

  @callback embed(model :: String.t(), texts :: [String.t()], opts :: keyword()) ::
              {:ok, [[float()]]} | {:error, term()}
end
