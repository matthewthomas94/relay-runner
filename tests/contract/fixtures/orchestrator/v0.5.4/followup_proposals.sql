PRAGMA user_version=0;
BEGIN TRANSACTION;
CREATE TABLE batches (
        id TEXT PRIMARY KEY,
        origin_repo_path TEXT NOT NULL,
        origin_ticket_id TEXT NOT NULL,
        origin_run_id INTEGER NOT NULL,
        provider_key TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );
CREATE TABLE proposals (
        id TEXT PRIMARY KEY,
        batch_id TEXT NOT NULL,
        position INTEGER NOT NULL,
        state TEXT NOT NULL,
        draft_json TEXT NOT NULL,
        ticket_id TEXT,
        error TEXT,
        updated_at REAL NOT NULL,
        UNIQUE(batch_id, position)
    );
CREATE INDEX idx_followup_proposals_batch ON proposals(batch_id, position);
COMMIT;
