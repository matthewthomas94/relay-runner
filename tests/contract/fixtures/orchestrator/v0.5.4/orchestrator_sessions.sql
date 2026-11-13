PRAGMA user_version=1;
BEGIN TRANSACTION;
CREATE TABLE orchestrator_sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_key TEXT NOT NULL UNIQUE,
        repo_path TEXT NOT NULL,
        provider_key TEXT NOT NULL,
        model_alias TEXT,
        effort TEXT,
        state TEXT NOT NULL,
        started_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        heartbeat_at REAL NOT NULL,
        stopped_at REAL,
        stop_reason TEXT,
        pid INTEGER,
        source TEXT
    );
INSERT INTO "orchestrator_sessions" VALUES(1,'project:e8097dc43aa7f935','<ROOT>/released','claude','opus','medium','idle',1794528616.1613948,1794528616.1613948,1794528616.1613948,NULL,NULL,NULL,'release-fixture');
CREATE INDEX idx_orchestrator_sessions_repo ON orchestrator_sessions(repo_path);
CREATE INDEX idx_orchestrator_sessions_state ON orchestrator_sessions(state);
DELETE FROM "sqlite_sequence";
INSERT INTO "sqlite_sequence" VALUES('orchestrator_sessions',1);
COMMIT;
