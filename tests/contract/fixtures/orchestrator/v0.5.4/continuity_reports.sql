PRAGMA user_version=0;
BEGIN TRANSACTION;
CREATE TABLE proposals (
        id TEXT PRIMARY KEY,
        report_id TEXT NOT NULL,
        position INTEGER NOT NULL,
        state TEXT NOT NULL,
        draft_json TEXT NOT NULL,
        ticket_id TEXT,
        error TEXT,
        updated_at REAL NOT NULL,
        UNIQUE(report_id, position)
    );
CREATE TABLE reports (
        id TEXT PRIMARY KEY,
        incident_id TEXT NOT NULL UNIQUE,
        state TEXT NOT NULL,
        report_json TEXT NOT NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );
CREATE INDEX idx_continuity_proposals_report
        ON proposals(report_id, position);
COMMIT;
