PRAGMA user_version=5;
BEGIN TRANSACTION;
CREATE TABLE runs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ticket_id TEXT NOT NULL,
        repo_path TEXT NOT NULL,
        workspace_path TEXT NOT NULL,
        branch TEXT NOT NULL,
        execution_mode TEXT NOT NULL DEFAULT 'implementation',
        state TEXT NOT NULL,
        attempt INTEGER NOT NULL DEFAULT 1,
        pid INTEGER,
        started_at REAL NOT NULL,
        ended_at REAL,
        exit_code INTEGER,
        log_path TEXT,
        last_error TEXT,
        activity TEXT,
        activity_at REAL,
        provider_key TEXT,
        model_alias TEXT,
        worker_model TEXT,
        worker_effort TEXT,
        worker_sizing_rationale TEXT,
        worker_provider_notes TEXT
    );
INSERT INTO "runs" VALUES(1,'CT-1','<ROOT>/released','<ROOT>/workspaces/released-e8097dc4-ct-1','relay/ct-1','implementation','Merged',1,41444,1794528612.8737569,1794528613.968137,0,'<ROOT>/workspaces/released-e8097dc4-ct-1/.relay/run.log',NULL,'Reviewing worker branch',1794528614.337425,'claude','sonnet','balanced','medium','A scripted change with no ambiguity.','none');
INSERT INTO "runs" VALUES(2,'CT-2','<ROOT>/released','<ROOT>/workspaces/released-e8097dc4-ct-2','relay/ct-2','implementation','Failed',1,41486,1794528615.121238,1794528615.8680079,3,'<ROOT>/workspaces/released-e8097dc4-ct-2/.relay/run.log','exit=3; tail={"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"cat .orchestrator/CT-2.md","description":"Read the ticket"}}]}} / {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"}]}} / {"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_2","name":"Bash","input":{"command":"swift build","description":"Build the project"}}]}} / {"type":"user","message":{"content":[{"type":"tool_resul','Running Swift build',1794528615.7080231,'claude','sonnet','balanced','medium','A scripted change with no ambiguity.','none');
INSERT INTO "runs" VALUES(3,'CT-3','<ROOT>/released','<ROOT>/workspaces/released-e8097dc4-ct-3','relay/ct-3','implementation','Merged',1,41597,1794528616.1405461,1794528616.968277,0,'<ROOT>/workspaces/released-e8097dc4-ct-3/.relay/run.log',NULL,'Reviewing worker branch',1794528617.3744221,'claude','sonnet','balanced','medium','A scripted change with no ambiguity.','none');
INSERT INTO "runs" VALUES(4,'CT-4','<ROOT>/released','<ROOT>/workspaces/released-e8097dc4-ct-4','relay/ct-4','implementation','Merged',1,41702,1794528618.005007,1794528618.8485971,0,'<ROOT>/workspaces/released-e8097dc4-ct-4/.relay/run.log',NULL,'Reviewing worker branch',1794528619.2285729,'claude','sonnet','balanced','medium','A scripted change with no ambiguity.','none');
CREATE INDEX idx_runs_state ON runs(state);
CREATE INDEX idx_runs_ticket ON runs(ticket_id);
DELETE FROM "sqlite_sequence";
INSERT INTO "sqlite_sequence" VALUES('runs',4);
COMMIT;
