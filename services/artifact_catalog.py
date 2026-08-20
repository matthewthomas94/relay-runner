"""Shared semantic validation for archived ticket catalog entries."""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Mapping, Sequence


UTC = timezone.utc
DEFAULT_ACTIVITY_FIELDS = (
    "activity_at",
    "user_edited_at",
    "pm_edited_at",
    "dependency_updated_at",
    "status_updated_at",
    "claimed_at",
    "run_outcome_at",
    "review_outcome_at",
    "merge_outcome_at",
    "attachment_updated_at",
    "restored_at",
    "reopened_at",
)


class CatalogSemanticError(ValueError):
    """The verified ticket Markdown disagrees with its catalog metadata."""


def validate_catalog_ticket_metadata(
    entry: Mapping[str, object],
    content: bytes,
    *,
    activity_fields: Sequence[str],
) -> dict[str, str]:
    """Parse verified Markdown and reject dependency-relevant catalog drift."""
    front = _front_matter(content)
    ticket_id = str(entry.get("ticket_id") or "")
    expected_path = f".orchestrator/{ticket_id}.md"
    if entry.get("ticket_path") != expected_path:
        raise CatalogSemanticError("archive catalog ticket path disagrees with ticket ID")

    _require_equal("ticket ID", ticket_id, front.get("id", ""))
    _require_equal("artifact ID", str(entry.get("artifact_id") or ""), front.get("artifact_id", ""))
    _require_equal("title", str(entry.get("title") or ticket_id), front.get("title", ticket_id))

    catalog_status = _canonical_status_value(str(entry.get("status") or ""))
    markdown_status = _canonical_status(front)
    _require_equal("status and canceled semantics", catalog_status, markdown_status)

    dependencies = entry.get("dependencies", [])
    if not isinstance(dependencies, list) or any(
        not isinstance(value, str) or not value.strip() for value in dependencies
    ):
        raise CatalogSemanticError("archive catalog dependencies are invalid")
    catalog_dependencies = tuple(sorted(value.strip() for value in dependencies))
    markdown_dependencies = tuple(sorted(_parse_list(front.get("depends_on", "[]"))))
    _require_equal("dependencies", catalog_dependencies, markdown_dependencies)

    activity_values = [
        _parse_instant(front[field])
        for field in activity_fields
        if front.get(field)
    ]
    if not activity_values:
        raise CatalogSemanticError("historical ticket has no durable activity timestamp")
    catalog_activity = _parse_instant(str(entry.get("activity_at") or ""))
    _require_equal("activity timestamp", catalog_activity, max(activity_values))
    return front


def _front_matter(content: bytes) -> dict[str, str]:
    try:
        lines = content.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise CatalogSemanticError("historical ticket front matter is not UTF-8") from error
    if not lines or lines[0].strip() != "---":
        raise CatalogSemanticError("historical ticket has no front matter")
    result: dict[str, str] = {}
    for line in lines[1:]:
        if line.strip() == "---":
            return result
        key, separator, value = line.partition(":")
        if separator:
            result[key.strip()] = value.strip().strip("\"'")
    raise CatalogSemanticError("historical ticket front matter is not closed")


def _parse_list(value: str) -> tuple[str, ...]:
    stripped = value.strip()
    if not stripped or stripped == "[]":
        return ()
    if stripped.startswith("[") and stripped.endswith("]"):
        stripped = stripped[1:-1]
    return tuple(
        item.strip().strip("\"'")
        for item in stripped.split(",")
        if item.strip().strip("\"'")
    )


def _parse_bool(value: str) -> bool:
    return value.strip().lower() in {"true", "yes", "1"}


def _canonical_status(front: Mapping[str, str]) -> str:
    if _parse_bool(front.get("canceled", "false")):
        return "canceled"
    return _canonical_status_value(front.get("status", "backlog"))


def _canonical_status_value(value: str) -> str:
    normalized = value.strip().lower()
    return "canceled" if normalized == "cancelled" else normalized


def _parse_instant(value: str) -> datetime:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise CatalogSemanticError(f"invalid historical activity timestamp: {value!r}") from error
    if parsed.tzinfo is None:
        raise CatalogSemanticError(f"historical activity timestamp has no UTC offset: {value!r}")
    return parsed.astimezone(UTC)


def _require_equal(label: str, catalog_value: object, markdown_value: object) -> None:
    if catalog_value != markdown_value:
        raise CatalogSemanticError(
            f"archive catalog {label} disagrees with verified historical Markdown"
        )
