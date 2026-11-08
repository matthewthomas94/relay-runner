Show or change how this Relay session routes change requests. The user picks the work style for the whole session from the Start button's menu; voice requests such as "switch to direct mode" and this command change the same choice. It applies to every project in the session from the next request, without restarting, and overrides a project's `work_style` in `.relay-runner.toml`.

| Style | What it does |
|---|---|
| `auto` | Decides per request: small, quick, reversible changes are done now; large or long work becomes a ticket. Asks when unsure. Default. |
| `direct` | Makes changes now in this session. A ticket only when the user asks for tracking, a worker or background work. |
| `orchestrated` | Turns every change request into a ticket for a worker. |

## Steps

1. Read the requested style from the arguments (`/work-style direct`). With no argument, show the current style and stop.
2. Run the helper. In an installed app it is `/Applications/Relay Runner.app/Contents/SharedSupport/scripts/relay-work-style`; inside the relay-runner repository, `scripts/relay-work-style` also works.

```bash
"/Applications/Relay Runner.app/Contents/SharedSupport/scripts/relay-work-style" set direct
```

   Use `show` instead of `set <style>` to read the effective style and whether it comes from the session's choice, the project's file or the default. Pass `--repo <path>` when the session's project is not the current directory's git project.
3. Confirm in one sentence: the new style and what it now does. Create no ticket and dispatch nothing.
