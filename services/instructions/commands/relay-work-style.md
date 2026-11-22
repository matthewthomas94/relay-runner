Show or change how you, the agent this session runs as, route change requests. Each agent (Puck, Isabella, George and Sky) has its own work style, set on its card in Relay Runner's Settings; voice requests such as "switch to direct mode" and this command change the same setting for this agent only. It applies to every project from the next request, without restarting, stays when the agent restarts, and overrides a project's `work_style` in `.relay-runner.toml`. The other agents keep theirs.

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

   The helper sets the style of the agent `RELAY_SESSION_AGENT` names, which Relay Runner exports to the session. Use `show` instead of `set <style>` to read the effective style and whether it comes from this agent's setting, the project's file or the default. Pass `--repo <path>` when the session's project is not the current directory's git project.
3. Confirm in one sentence: the new style and what it now does. Create no ticket and dispatch nothing.
