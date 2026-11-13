PRAGMA user_version=2;
BEGIN TRANSACTION;
CREATE TABLE messenger_dispatchers (
        repo_path TEXT NOT NULL,
        ticket_id TEXT NOT NULL,
        session_key TEXT NOT NULL,
        updated_at REAL NOT NULL,
        PRIMARY KEY (repo_path, ticket_id)
    );
CREATE TABLE messenger_outcomes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        event_key TEXT NOT NULL UNIQUE,
        repo_path TEXT NOT NULL,
        provider_key TEXT,
        kind TEXT NOT NULL,
        ticket_id TEXT,
        run_id INTEGER,
        message TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        created_at REAL NOT NULL,
        delivered_at REAL,
        delivery_attempts INTEGER NOT NULL DEFAULT 0,
        session_key TEXT
    );
INSERT INTO "messenger_outcomes" VALUES(1,'<ROOT>/released|reasoning-summary|||orchestrator','<ROOT>/released','claude','reasoning-summary',NULL,NULL,'Started queue drain drain-55c0a690382f-1.','{"text": "Started queue drain drain-55c0a690382f-1.", "trace_event": {"kind": "reasoning-summary", "lifecycle_detail": "Started queue drain drain-55c0a690382f-1.", "message": "Started queue drain drain-55c0a690382f-1.", "source": "orchestrator"}}',1794528612.9179001,NULL,0,NULL);
INSERT INTO "messenger_outcomes" VALUES(2,'<ROOT>/released|run-review-needed|CT-1|1|worker','<ROOT>/released','claude','run-review-needed','CT-1',1,'CT-1 run 1 awaiting review','{"text": "CT-1 run 1 awaiting review", "trace_event": {"kind": "run-review-needed", "lifecycle_detail": "CT-1 run 1 awaiting review", "message": "CT-1 run 1 awaiting review", "run_id": 1, "source": "worker", "ticket_id": "CT-1"}}',1794528613.972579,NULL,0,NULL);
INSERT INTO "messenger_outcomes" VALUES(3,'<ROOT>/released|run-merged|CT-1|1|orchestrator','<ROOT>/released','claude','run-merged','CT-1',1,'CT-1 run 1 merged','{"text": "CT-1 run 1 merged", "trace_event": {"kind": "run-merged", "lifecycle_detail": "CT-1 run 1 merged", "message": "CT-1 run 1 merged", "run_id": 1, "source": "orchestrator", "ticket_id": "CT-1"}}',1794528614.7218828,NULL,0,NULL);
INSERT INTO "messenger_outcomes" VALUES(4,'<ROOT>/released|run-failed|CT-2|2|worker','<ROOT>/released','claude','run-failed','CT-2',2,'CT-2 run 2 failed','{"text": "CT-2 run 2 failed", "trace_event": {"kind": "run-failed", "lifecycle_detail": "CT-2 run 2 failed", "message": "CT-2 run 2 failed", "run_id": 2, "source": "worker", "ticket_id": "CT-2"}}',1794528615.87187,NULL,0,NULL);
INSERT INTO "messenger_outcomes" VALUES(5,'<ROOT>/released|run-review-needed|CT-3|3|worker','<ROOT>/released','claude','run-review-needed','CT-3',3,'CT-3 run 3 awaiting review','{"text": "CT-3 run 3 awaiting review", "trace_event": {"kind": "run-review-needed", "lifecycle_detail": "CT-3 run 3 awaiting review", "message": "CT-3 run 3 awaiting review", "run_id": 3, "source": "worker", "ticket_id": "CT-3"}}',1794528616.9729011,NULL,0,NULL);
INSERT INTO "messenger_outcomes" VALUES(6,'<ROOT>/released|run-merged|CT-3|3|orchestrator','<ROOT>/released','claude','run-merged','CT-3',3,'CT-3 run 3 merged','{"text": "CT-3 run 3 merged", "trace_event": {"kind": "run-merged", "lifecycle_detail": "CT-3 run 3 merged", "message": "CT-3 run 3 merged", "run_id": 3, "source": "orchestrator", "ticket_id": "CT-3"}}',1794528617.8081842,NULL,0,NULL);
INSERT INTO "messenger_outcomes" VALUES(7,'<ROOT>/released|run-review-needed|CT-4|4|worker','<ROOT>/released','claude','run-review-needed','CT-4',4,'CT-4 run 4 awaiting review','{"text": "CT-4 run 4 awaiting review", "trace_event": {"kind": "run-review-needed", "lifecycle_detail": "CT-4 run 4 awaiting review", "message": "CT-4 run 4 awaiting review", "run_id": 4, "source": "worker", "ticket_id": "CT-4"}}',1794528618.8528309,NULL,0,NULL);
INSERT INTO "messenger_outcomes" VALUES(8,'<ROOT>/released|run-merged|CT-4|4|orchestrator','<ROOT>/released','claude','run-merged','CT-4',4,'CT-4 run 4 merged','{"text": "CT-4 run 4 merged", "trace_event": {"kind": "run-merged", "lifecycle_detail": "CT-4 run 4 merged", "message": "CT-4 run 4 merged", "run_id": 4, "source": "orchestrator", "ticket_id": "CT-4"}}',1794528619.6739531,NULL,0,NULL);
CREATE INDEX idx_messenger_outcomes_repo_pending
        ON messenger_outcomes(repo_path, delivered_at, id);
DELETE FROM "sqlite_sequence";
INSERT INTO "sqlite_sequence" VALUES('messenger_outcomes',8);
COMMIT;
