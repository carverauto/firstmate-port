# Diagrams

Archify specifications and the HTML they render to. The `.architecture.json`
file is the source; the `.html` beside it is checked in so a reviewer can open
the diagram without the Archify skill installed.

Regenerate after editing a specification:

```sh
archify deliver architecture docs/diagrams/<name>.architecture.json \
  docs/diagrams/<name>.html --quality showcase
```

`archify visual-check <name>.html` writes screenshots and a receipt next to the
artifact. Those are evidence for the person making the change, not repository
content — `.gitignore` keeps them out.

| Diagram | What it settles |
| --- | --- |
| [`public-vs-discord-hostnames`](public-vs-discord-hostnames.html) | Which hostname serves what: the portal on LAN `firstmate.carverauto.dev` (`192.168.6.87`), path-only `/interactions` on public `discord-firstmate.carverauto.dev`. See [docs/security.md](../security.md). |
| [`discord-inbound`](discord-inbound.html) | The public Discord interactions path, from the Cloudflare edge to `<tenant>.discord.inbound`. See [docs/credentials.md](../credentials.md). |
