# ReqLLM's model catalogue is loaded lazily into `:persistent_term` on its first
# use, and that write pauses every process in the VM for long enough to trip a
# database checkout elsewhere in an async suite. Pay for it once, here, before
# any test owns a connection.
_ = LLMDB.load()

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(FirstmatePort.Repo, :manual)
