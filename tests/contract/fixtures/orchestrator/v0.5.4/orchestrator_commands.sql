PRAGMA user_version=5;
BEGIN TRANSACTION;
CREATE TABLE orchestrator_commands (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        intent_id TEXT NOT NULL UNIQUE,
        relay_command_id TEXT NOT NULL,
        relay_command_seq INTEGER NOT NULL,
        within_turn_order INTEGER NOT NULL DEFAULT 1,
        session_id INTEGER,
        repo_path TEXT NOT NULL,
        provider_key TEXT,
        recovery_generation TEXT NOT NULL DEFAULT '0',
        source_text TEXT NOT NULL,
        context TEXT,
        action TEXT,
        outcome TEXT,
        ticket_id TEXT,
        target TEXT,
        disposition TEXT,
        cancellation_scope TEXT NOT NULL DEFAULT 'none',
        lifecycle_state TEXT NOT NULL DEFAULT 'recognized',
        status TEXT NOT NULL,
        status_message TEXT,
        error TEXT,
        received_at REAL,
        processed_at REAL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );
CREATE INDEX idx_orchestrator_commands_repo ON orchestrator_commands(repo_path);
CREATE INDEX idx_orchestrator_commands_status ON orchestrator_commands(status);
CREATE UNIQUE INDEX idx_orchestrator_commands_turn_order
        ON orchestrator_commands(relay_command_id, within_turn_order);
DELETE FROM "sqlite_sequence";
COMMIT;
