# Assistant contexts and personal files

Start Session defaults to the preinstalled **general-tasks** project at `~/Library/Application Support/relay-runner/general-tasks`. It appears in the existing Projects list beside the user's repositories and uses the ordinary project board and ticket workflow. The app creates and registers this private local working area automatically; selecting a repository or connecting GitHub is unnecessary.

The Workspace retains Workspace, Notes, Terminal and Settings. There is no separate Files tab, Conversation tab or General context switcher. Existing centralized notes retain their identities and recovery data. Operational databases, logs and provider bindings stay outside the general-tasks folder.

Selecting another project saves the prior provider session and uses that project's confirmed directory and ticket ownership. Codex and Claude resume their exact recorded native session when available. Recording, accepted foreground work and approvals defer replacement; restart does not replay saved commands.

## General task decisions

The foreground PM applies the existing [Task / Action / Discussion matrix](../intent-qualification-testing.md). Discussion and small bounded actions remain foreground. Substantial deliverables, multi-step work and explicitly tracked or delegated work use normal tickets in general-tasks. Repository-specific implementation belongs to its confirmed source repository. General-task drafts and deliverables live inside the managed project folder.

## Optional private storage

Users can start locally and connect GitHub later in Settings. Setup uses the authenticated GitHub account, suggests `<login>-rr-files`, and explicitly creates or adopts a private, identified storage repository. Account, immutable repository identity, destination and privacy are revalidated before remote operations. An unrelated naming collision is never adopted automatically.

Only approved personal notes, task deliverables and documents are synchronized. Provider credentials, terminal logs, project boards, operational databases and runtime files are excluded. Uploads use immutable verified content revisions and normal forward publication. Offline, authentication and conflict states preserve local work and provide a retry path. Disconnect stops synchronization without deleting local or remote files.

The local budget includes files, legacy notes Git objects, cache and storage metadata. Unsynchronized, pinned and active files remain protected. Eviction requires verified publication and an exact remote revision, then rechecks local content before removal. Files can be searched and fetched on demand with checksum verification; retrieval does not retain a full remote Git clone. Legacy notes history is only removed locally after a verified history archive and compatible note migration. The app reports protected overage rather than discarding unique work. Remote history has no automatic destructive purge.

## Validation boundaries

Focused source tests cover General/project scope, both provider command contracts, safe switching, durable history, interruption, task lifecycle, storage identity/conflict handling and verified cache eviction. Installed app behavior, native subscription sessions, browser GitHub setup and visual or audible UAT require separate recorded evidence. Test doubles do not prove real GitHub publication or installed interaction.
