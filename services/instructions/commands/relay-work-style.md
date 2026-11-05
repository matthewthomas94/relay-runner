Show or change how this project's Relay sessions route change requests. The choice is saved for the project and applies from the next request, without restarting the session. The Workspace's Start menu and voice requests such as "switch to direct mode" change the same setting.

| Style | What it does |
|---|---|
| `auto` | Decides per request: small, quick, reversible changes are done now; large or long work becomes a ticket. Asks when unsure. Default. |
| `direct` | Makes changes now in this session. A ticket only when the user asks for tracking, a worker or background work. |
| `orchestrated` | Turns every change request into a ticket for a worker. |

## Steps

1. Read the requested style from the arguments (`/work-style direct`). With no argument, show the current style and stop.
2. Run the helper for the current project. In an installed app it is `/Applications/Relay Runner.app/Contents/SharedSupport/scripts/relay-work-style`; inside the relay-runner repository, `scripts/relay-work-style` also works.

```bash
"/Applications/Relay Runner.app/Contents/SharedSupport/scripts/relay-work-style" set direct
```

   Use `show` instead of `set <style>` to read it. Pass `--repo <path>` when the session's project is not the current directory's git project.
3. Confirm in one sentence: the project, the new style and what it now does. Create no ticket and dispatch nothing.
