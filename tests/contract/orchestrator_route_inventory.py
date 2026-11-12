"""The orchestrator daemon's route table, read from the reference source.

`Handler._route` in services/orchestrator.py matches each request with `if`
tests on `method` and the path `segments`; the personal-storage routes are
matched by `handle_personal_storage_request` in
services/personal_file_storage.py. This module parses both files with `ast`.
It never imports them, so the contract suite still imports nothing from
`services/`.

A test shape the parser does not recognise fails loudly: update this parser
and docs/specs/orchestrator-http-api.md together.
"""

from __future__ import annotations

import ast
import re
from pathlib import Path

SERVICES = Path(__file__).resolve().parents[2] / "services"
DAEMON_SOURCE = SERVICES / "orchestrator.py"
PERSONAL_STORAGE_SOURCE = SERVICES / "personal_file_storage.py"
API_DOCUMENT = Path(__file__).resolve().parents[2] / "docs" / "specs" / "orchestrator-http-api.md"

PARAMETER = "{}"
# Names an `if` test may discriminate a route on. `operation` is the General
# task verb taken from the fifth path segment; `route` is the personal-storage
# path after `/v1/personal-storage/`.
ROUTE_NAMES = {"method", "segments", "operation", "route"}


class UnrecognisedRoute(AssertionError):
    pass


def _function(path: Path, name: str, owner: str = None, text: str = None) -> ast.FunctionDef:
    source = path.read_text(encoding="utf-8") if text is None else text
    tree = ast.parse(source, filename=str(path))
    for node in ast.walk(tree):
        if owner and isinstance(node, ast.ClassDef) and node.name == owner:
            for item in node.body:
                if isinstance(item, ast.FunctionDef) and item.name == name:
                    return item
        if not owner and isinstance(node, ast.FunctionDef) and node.name == name:
            return node
    raise UnrecognisedRoute("%s has no %s" % (path, name))


def _names(node: ast.AST) -> set:
    return {item.id for item in ast.walk(node) if isinstance(item, ast.Name)}


def _literal(node: ast.AST):
    try:
        return ast.literal_eval(node)
    except ValueError as error:
        raise UnrecognisedRoute("not a literal at line %d" % node.lineno) from error


class _Constraint:
    """What one chain of `if` tests says about the request."""

    def __init__(self):
        self.methods = None
        self.exact = None          # list of alternative full segment lists
        self.prefix = []
        self.length = None
        self.positions = {}        # index -> set of literal values
        self.operation = None      # General task verb
        self.route = None          # personal-storage route

    def copy(self) -> "_Constraint":
        other = _Constraint()
        other.methods = self.methods
        other.exact = self.exact
        other.prefix = list(self.prefix)
        other.length = self.length
        other.positions = {key: set(value) for key, value in self.positions.items()}
        other.operation = self.operation
        other.route = self.route
        return other

    def add(self, test: ast.AST) -> None:
        if isinstance(test, ast.BoolOp) and isinstance(test.op, ast.And):
            for value in test.values:
                self.add(value)
            return
        if not isinstance(test, ast.Compare) or len(test.ops) != 1:
            raise UnrecognisedRoute("unrecognised route test at line %d" % test.lineno)
        left, op, right = test.left, test.ops[0], test.comparators[0]
        if isinstance(left, ast.Name) and left.id == "method" and isinstance(op, ast.Eq):
            self.methods = {_literal(right)}
        elif isinstance(left, ast.Name) and left.id == "segments" and isinstance(op, ast.Eq):
            self.exact = [list(_literal(right))]
        elif isinstance(left, ast.Name) and left.id == "segments" and isinstance(op, ast.In):
            self.exact = [list(item) for item in _literal(right)]
        elif (isinstance(left, ast.Call) and isinstance(left.func, ast.Name)
              and left.func.id == "len" and isinstance(op, ast.Eq)):
            self.length = _literal(right)
        elif (isinstance(left, ast.Subscript) and isinstance(left.value, ast.Name)
              and left.value.id == "segments"):
            index = left.slice
            if isinstance(index, ast.Slice) and isinstance(op, ast.Eq):
                self.prefix = list(_literal(right))
            elif isinstance(op, ast.Eq):
                self.positions[_literal(index)] = {_literal(right)}
            elif isinstance(op, ast.In):
                self.positions[_literal(index)] = set(_literal(right))
            else:
                raise UnrecognisedRoute("unrecognised segment test at line %d" % test.lineno)
        elif isinstance(left, ast.Name) and left.id == "operation" and isinstance(op, ast.Eq):
            self.operation = _literal(right)
        elif isinstance(left, ast.Name) and left.id == "route" and isinstance(op, ast.Eq):
            self.route = _literal(right)
        else:
            raise UnrecognisedRoute("unrecognised route test at line %d" % test.lineno)

    def paths(self) -> list:
        if self.route is not None:
            return ["/v1/personal-storage/" + self.route]
        if self.exact is not None:
            return ["/" + "/".join(segments) for segments in self.exact]
        length = self.length
        positions = dict(self.positions)
        if self.operation is not None:
            # `operation` is "create" for the collection, else segments[4].
            if self.operation == "create":
                length = len(self.prefix)
            else:
                length = 5
                positions[4] = {self.operation}
        if length is None:
            raise UnrecognisedRoute("route %s has no fixed length" % self.prefix)
        results = [[]]
        for index in range(length):
            if index < len(self.prefix):
                choices = [self.prefix[index]]
            elif index in positions:
                choices = sorted(positions[index])
            else:
                choices = [PARAMETER]
            results = [result + [choice] for result in results for choice in choices]
        return ["/" + "/".join(result) for result in results]


def _is_route_test(node: ast.If) -> bool:
    """A test on the request whose branch answers it. Other tests are guards."""
    answers = any(isinstance(item, ast.Return) for item in ast.walk(node))
    return answers and bool(_names(node.test) & ROUTE_NAMES)


def _nested_route_ifs(body) -> list:
    found = []
    for statement in body:
        for node in ast.walk(statement):
            if isinstance(node, ast.If) and _is_route_test(node):
                found.append(node)
    return found


def _collect(body, constraint: _Constraint, routes: set, personal) -> None:
    for statement in body:
        if isinstance(statement, ast.Try):
            _collect(statement.body, constraint, routes, personal)
            continue
        if not isinstance(statement, ast.If):
            continue
        if not _is_route_test(statement):
            continue
        tested = constraint.copy()
        tested.add(statement.test)
        if tested.prefix == ["v1", "personal-storage"]:
            routes.update(personal())
            continue
        if _nested_route_ifs(statement.body):
            _collect(statement.body, tested, routes, personal)
        else:
            if not tested.methods:
                raise UnrecognisedRoute("route at line %d has no method" % statement.lineno)
            for method in tested.methods:
                for path in tested.paths():
                    routes.add((method, path))
        if statement.orelse:
            raise UnrecognisedRoute("route test at line %d has an else branch" % statement.lineno)


def _personal_storage_routes(text: str = None) -> set:
    function = _function(PERSONAL_STORAGE_SOURCE, "handle_personal_storage_request", text=text)
    routes = set()
    _collect(function.body, _Constraint(), routes, lambda: set())
    return routes


def source_routes(daemon_text: str = None, storage_text: str = None) -> set:
    """Every (method, path) the reference daemon serves; parameters are `{}`.

    The texts default to the files on disk; a test passes edited copies.
    """
    function = _function(DAEMON_SOURCE, "_route", owner="Handler", text=daemon_text)
    routes = set()
    _collect(function.body, _Constraint(), routes, lambda: _personal_storage_routes(storage_text))
    return routes


_ROW_RE = re.compile(r"^\|\s*(GET|POST)\s*\|\s*`([^`]+)`\s*\|")


def documented_routes(text: str = None) -> dict:
    """The route index of the API document: (method, path) -> the documented template."""
    text = API_DOCUMENT.read_text(encoding="utf-8") if text is None else text
    routes = {}
    for line in text.splitlines():
        match = _ROW_RE.match(line)
        if match:
            method, template = match.groups()
            key = (method, normalise(template))
            if key in routes:
                raise AssertionError("route listed twice: %s %s" % (method, template))
            routes[key] = template
    return routes


def normalise(template: str) -> str:
    return re.sub(r"\{[^}/]*\}", PARAMETER, template.split("?", 1)[0])


if __name__ == "__main__":  # pragma: no cover - a maintenance aid
    for method, path in sorted(source_routes(), key=lambda item: (item[1], item[0])):
        print(method, path)
