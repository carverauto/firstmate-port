defmodule FirstmatePort.Fleet.Embeddings.ReqLLMClient do
  @moduledoc """
  The shipped client. `ReqLLM` already speaks every provider we would otherwise
  write an adapter for, so this is the whole integration: a model spec, the
  texts, and the tenant's key passed per request.

  The key is passed as a request option and never written to application
  environment, which is what keeps one tenant's key out of another tenant's
  request.

  The first call on a node loads `ReqLLM`'s model catalogue, which takes a few
  seconds. That is why the embedding backfill runs in its own low-concurrency
  queue and never on a request path.
  """

  @behaviour FirstmatePort.Fleet.Embeddings.Client

  @impl true
  def embed(model, texts, opts) do
    case ReqLLM.embed(model, texts, opts) do
      {:ok, vectors} when is_list(vectors) -> {:ok, vectors}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, reason} -> {:error, reason}
    end
  end
end
