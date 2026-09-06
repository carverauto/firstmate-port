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
| [`public-vs-discord-hostnames`](public-vs-discord-hostnames.html) | Which hostname serves what, now that the portal is public: the whole app on `firstmate.carverauto.dev`, path-only `/interactions` on `discord-firstmate.carverauto.dev`, and the security plugs both pass through. See [docs/security.md](../security.md). |
