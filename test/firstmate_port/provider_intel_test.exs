defmodule FirstmatePort.Router.ProviderIntelTest do
  use ExUnit.Case, async: true

  alias FirstmatePort.Router
  alias FirstmatePort.Router.ProviderIntel

  test "a string context_length still ranks, and never raises" do
    intel = %{
      models:
        ProviderIntel.parse_openrouter_models(%{
          "data" => [
            %{
              "id" => "openai/roomy",
              "pricing" => %{"prompt" => "5.0"},
              "context_length" => "128000"
            },
            %{
              "id" => "openai/cramped",
              "pricing" => %{"prompt" => "0.5"},
              "context_length" => "1000"
            }
          ]
        }),
      benchmarks: [],
      sources: ["openrouter"]
    }

    assert {"openai/roomy", "openrouter", _} = ProviderIntel.select_model("codex", intel)
  end

  test "non-scalar provider JSON degrades to empty metadata instead of raising" do
    [row] =
      ProviderIntel.parse_openrouter_models(%{
        "data" => [
          %{
            "id" => "openai/weird",
            "pricing" => %{"prompt" => %{"per_token" => 1}, "completion" => ["1.0"]},
            "context_length" => %{"max" => 128_000}
          }
        ]
      })

    assert row.prompt_price == nil
    assert row.completion_price == nil
    assert row.context == 0

    intel = %{models: [row], benchmarks: [], sources: ["openrouter"]}
    got = Router.route("fix the failing test in the ingest controller", intel: intel)

    assert got.harness == "codex"
    assert got.model == "harness-default"
  end
end
