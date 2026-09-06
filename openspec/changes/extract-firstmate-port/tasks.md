# Tasks

- [x] Extract Phoenix/Ash portal, k8s, fm-steer; omit notify.py/watch.py/plist
- [x] Rename hub to firstmate-port
- [x] Scrub compiled-in site identity and secrets
- [x] Bazel (rules_elixir, BuildBuddy remote, isolated output base)
- [x] Docker Compose (portal, Postgres, JetStream) and Harbor publish docs
- [x] Tailwind v4 operator UI with Geist, login, empty/loading/error states
- [x] fm-steer device-code + HTTP inbox (no NATS in the CLI)
- [x] Attribute tenancy on shared Postgres and one NATS account; streams `<tenant>.steer` / `<tenant>.inbound`; seed tenant local as example
- [x] Durable tenant inbox with a portal view; CLI sessions listed and revocable; GitHub PAT read from the credential store
