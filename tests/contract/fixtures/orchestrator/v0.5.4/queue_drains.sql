PRAGMA user_version=1;
BEGIN TRANSACTION;
CREATE TABLE queue_drain_items (
        drain_id TEXT NOT NULL,
        ticket_id TEXT NOT NULL,
        state TEXT NOT NULL,
        run_id INTEGER,
        reason TEXT,
        next_action_at REAL,
        blocker_owner TEXT,
        blocker_next_step TEXT,
        unresolved_dependencies TEXT NOT NULL DEFAULT '[]',
        updated_at REAL NOT NULL,
        PRIMARY KEY(drain_id, ticket_id)
    );
INSERT INTO "queue_drain_items" VALUES('drain-55c0a690382f-1','CT-1','done',1,'source ticket is done',NULL,NULL,NULL,'[]',1794528614.7531991);
INSERT INTO "queue_drain_items" VALUES('drain-55c0a690382f-1','CT-3','done',3,'source ticket is done',NULL,NULL,NULL,'[]',1794528618.0204721);
INSERT INTO "queue_drain_items" VALUES('drain-55c0a690382f-1','CT-4','done',4,'source ticket is done',NULL,NULL,NULL,'[]',1794528619.6807392);
INSERT INTO "queue_drain_items" VALUES('drain-55c0a690382f-1','CT-2','scheduled',2,'automatic retry backoff active after attempt 1; retry in 26s',1794528645.8680079,NULL,NULL,'[]',1794528618.9726679);
CREATE TABLE queue_drains (
        id TEXT PRIMARY KEY,
        repo_path TEXT NOT NULL,
        target_branch TEXT NOT NULL,
        provider_key TEXT NOT NULL,
        provider_goal_id TEXT,
        provider_goal_state TEXT NOT NULL,
        provider_goal_mode TEXT NOT NULL,
        state TEXT NOT NULL,
        status_message TEXT,
        observed_ticket_ids TEXT NOT NULL DEFAULT '[]',
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        quiescent_since REAL,
        completed_at REAL,
        canceled_at REAL
    );
INSERT INTO "queue_drains" VALUES('drain-55c0a690382f-1','<ROOT>/released','main','claude','drain-55c0a690382f-1','active','relay-runner-durable-goal','active','Queue drain waiting on 1 ticket(s).','["CT-1", "CT-2", "CT-3", "CT-4"]',1794528612.9145291,1794528619.6867662,NULL,NULL,NULL);
CREATE INDEX idx_queue_drains_repo_state
        ON queue_drains(repo_path, state);
CREATE INDEX idx_queue_drain_items_ticket
        ON queue_drain_items(ticket_id);
COMMIT;
