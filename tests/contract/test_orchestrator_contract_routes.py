"""The route table: the API document and a live daemon agree.

docs/specs/orchestrator-http-api.md lists every route in its "Route index".
The probe case sends every listed route to a running daemon with empty input
and compares each answer with a golden file, which pins the principal error
(or the success shape) of every route.
"""

from __future__ import annotations

import unittest

from orchestrator_contract_support import DaemonCase
from orchestrator_route_inventory import PARAMETER, documented_routes, normalise

# Path parameters for the probe. Each names nothing that exists.
PROBE_PARAMETER = "999"
# The documented defect: these two raise KeyError, and the daemon closes the
# connection, unless the body names an artifact.
PROBE_BODIES = {
    "/v1/personal-storage/pin": {"artifact_id": "missing"},
    "/v1/personal-storage/retrieve": {"artifact_id": "missing"},
}


class RouteInventoryTests(unittest.TestCase):
    def test_the_document_lists_every_route_once(self):
        self.assertEqual(len(documented_routes()), 76, "route count changed; update the API document")

    def test_parameters_are_normalised(self):
        self.assertEqual(normalise("/v1/runs/{run_id}/review"), "/v1/runs/%s/review" % PARAMETER)
        self.assertEqual(normalise("/v1/runs?limit=1"), "/v1/runs")


class RouteProbeTests(DaemonCase):
    def test_every_documented_route_answers_empty_input(self):
        answers = {}
        for (method, _path), template in sorted(
            documented_routes().items(), key=lambda item: (item[1], item[0][0]),
        ):
            path = normalise(template).replace(PARAMETER, PROBE_PARAMETER)
            body = PROBE_BODIES.get(path, {}) if method == "POST" else None
            response = self.box.request(method, path, body)
            self.assertIsInstance(response.json, dict, "%s %s: %r" % (method, path, response))
            self.assertNotIn(
                "no route for", str(response.json.get("error", "")), "%s %s" % (method, path),
            )
            if "error" in response.json:
                answer = {"status": response.status, "error": response.json["error"]}
            else:
                answer = {"status": response.status, "keys": sorted(response.json)}
            answers["%s %s" % (method, template)] = answer
        self.box.assert_golden_json("routes/empty-input", answers)

    def test_an_unknown_route_is_a_404(self):
        response = self.assertStatus(self.box.get("/v1/contract/nowhere"), 404)
        self.assertEqual(response.json, {"error": "no route for GET /v1/contract/nowhere"})
        response = self.assertStatus(self.box.post("/v1/health"), 404)
        self.assertEqual(response.json, {"error": "no route for POST /v1/health"})

    def test_health_names_the_server(self):
        response = self.assertStatus(self.box.get("/v1/health"), 200)
        self.assertEqual(response.json, {"ok": True, "version": "RelayOrchestrator/0.1"})
        self.assertEqual(response.headers["Content-Type"], "application/json")

    def test_a_body_that_is_not_an_object_reads_as_empty(self):
        for raw in (b"[1, 2]", b"{not json", b""):
            response = self.box.request("POST", "/v1/runs", raw=raw)
            self.assertError(response, 400, "ticket_id is required")


if __name__ == "__main__":
    unittest.main()
