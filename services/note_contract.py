"""Provider-neutral project note document and checkpoint contracts.

Project notes are human-readable Markdown artifacts. Segment metadata is kept in
canonical HTML comments so the transcript remains useful in Git while recorder
clients can round-trip stable segment identities and capture timing.
"""

from __future__ import annotations

import dataclasses
import json
import re
from datetime import datetime
from typing import Mapping, Sequence


NOTE_SCHEMA_VERSION = 1
NOTE_INDEX_SCHEMA_VERSION = 1
NOTE_MAX_BYTES = 8 * 1024 * 1024
NOTE_RECORDING_STATES = frozenset({"recording", "paused", "completed"})
NOTE_CHECKPOINT_REASONS = frozenset({"checkpoint", "pause", "resume", "complete", "manual"})

_NOTE_ID_RE = re.compile(r"^(?P<prefix>[A-Za-z0-9]+)-N(?P<number>[1-9][0-9]*)$")
_SAFE_ID_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,160}$")
_ARTIFACT_ID_RE = re.compile(r"^[A-Za-z0-9_.:-]{8,160}$")
_OBJECT_ID_RE = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
_DIGEST_RE = re.compile(r"^[0-9a-f]{64}$")
_SEGMENT_MARKER = "<!-- relay-note-segment "
_SEGMENT_RE = re.compile(r"^<!-- relay-note-segment (\{.*\}) -->$", re.MULTILINE)


class NoteContractError(ValueError):
    """A note document or checkpoint violates the shared storage contract."""


@dataclasses.dataclass(frozen=True)
class NoteIdentity:
    note_id: str
    artifact_id: str
    project_id: str
    created_at: str
    capture_started_at: str

    @classmethod
    def from_mapping(cls, value: Mapping[str, object]) -> "NoteIdentity":
        identity = cls(
            note_id=str(value.get("note_id") or ""),
            artifact_id=str(value.get("artifact_id") or ""),
            project_id=str(value.get("project_id") or ""),
            created_at=str(value.get("created_at") or ""),
            capture_started_at=str(value.get("capture_started_at") or ""),
        )
        validate_note_id(identity.note_id)
        if not _ARTIFACT_ID_RE.fullmatch(identity.artifact_id):
            raise NoteContractError("note immutable artifact_id is invalid")
        if not _SAFE_ID_RE.fullmatch(identity.project_id):
            raise NoteContractError("note project_id is invalid")
        validate_timestamp(identity.created_at, "note created_at")
        validate_timestamp(identity.capture_started_at, "note capture_started_at")
        return identity

    def as_dict(self) -> dict[str, object]:
        return dataclasses.asdict(self)


@dataclasses.dataclass(frozen=True)
class NoteSegment:
    segment_id: str
    captured_at: str
    text: str
    start_ms: int | None = None
    end_ms: int | None = None
    speaker: str | None = None

    @classmethod
    def from_mapping(cls, value: Mapping[str, object]) -> "NoteSegment":
        start_ms = _optional_nonnegative_int(value.get("start_ms"), "segment start_ms")
        end_ms = _optional_nonnegative_int(value.get("end_ms"), "segment end_ms")
        if start_ms is not None and end_ms is not None and end_ms < start_ms:
            raise NoteContractError("segment end_ms cannot precede start_ms")
        speaker_value = value.get("speaker")
        speaker = str(speaker_value).strip() if speaker_value is not None else None
        if speaker is not None and (
            not speaker
            or len(speaker.encode("utf-8")) > 160
            or "-->" in speaker
            or any(ord(character) < 32 for character in speaker)
        ):
            raise NoteContractError("segment speaker must be 1 to 160 UTF-8 bytes")
        text = str(value.get("text") or "").rstrip()
        if not text.strip():
            raise NoteContractError("segment text is required")
        if _SEGMENT_MARKER in text:
            raise NoteContractError("segment text contains reserved Relay note metadata")
        segment = cls(
            segment_id=str(value.get("segment_id") or ""),
            captured_at=str(value.get("captured_at") or ""),
            text=text,
            start_ms=start_ms,
            end_ms=end_ms,
            speaker=speaker,
        )
        if not _SAFE_ID_RE.fullmatch(segment.segment_id):
            raise NoteContractError("segment_id is invalid")
        validate_timestamp(segment.captured_at, "segment captured_at")
        return segment

    def metadata(self) -> dict[str, object]:
        value: dict[str, object] = {
            "captured_at": self.captured_at,
            "segment_id": self.segment_id,
        }
        if self.start_ms is not None:
            value["start_ms"] = self.start_ms
        if self.end_ms is not None:
            value["end_ms"] = self.end_ms
        if self.speaker is not None:
            value["speaker"] = self.speaker
        return value

    def as_dict(self) -> dict[str, object]:
        return {**self.metadata(), "text": self.text}


@dataclasses.dataclass(frozen=True)
class NoteUpdate:
    identity: NoteIdentity
    captured_at: str
    recording_state: str
    checkpoint_reason: str
    segments: tuple[NoteSegment, ...]
    capture_ended_at: str | None = None

    @classmethod
    def from_mapping(cls, value: Mapping[str, object]) -> "NoteUpdate":
        raw_identity = value.get("identity")
        if not isinstance(raw_identity, Mapping):
            raise NoteContractError("note update identity is required")
        return cls.from_values(
            identity=NoteIdentity.from_mapping(raw_identity),
            captured_at=str(value.get("captured_at") or ""),
            recording_state=str(value.get("recording_state") or ""),
            checkpoint_reason=str(value.get("checkpoint_reason") or ""),
            raw_segments=value.get("segments"),
            capture_ended_at=(
                str(value["capture_ended_at"])
                if value.get("capture_ended_at") is not None
                else None
            ),
        )

    @classmethod
    def from_values(
        cls,
        *,
        identity: NoteIdentity,
        captured_at: str,
        recording_state: str,
        checkpoint_reason: str,
        raw_segments: object,
        capture_ended_at: str | None = None,
    ) -> "NoteUpdate":
        validate_timestamp(captured_at, "note captured_at")
        if recording_state not in NOTE_RECORDING_STATES:
            raise NoteContractError("note recording_state is invalid")
        if checkpoint_reason not in NOTE_CHECKPOINT_REASONS:
            raise NoteContractError("note checkpoint_reason is invalid")
        if capture_ended_at is not None:
            validate_timestamp(capture_ended_at, "note capture_ended_at")
        if (recording_state == "completed") != (capture_ended_at is not None):
            raise NoteContractError(
                "capture_ended_at is required exactly when recording_state is completed"
            )
        if not isinstance(raw_segments, Sequence) or isinstance(raw_segments, (str, bytes)):
            raise NoteContractError("note segments must be an array")
        segments: list[NoteSegment] = []
        seen: set[str] = set()
        for raw in raw_segments:
            if not isinstance(raw, Mapping):
                raise NoteContractError("each note segment must be an object")
            segment = NoteSegment.from_mapping(raw)
            if segment.segment_id in seen:
                raise NoteContractError(f"duplicate note segment_id: {segment.segment_id}")
            seen.add(segment.segment_id)
            segments.append(segment)
        return cls(
            identity=identity,
            captured_at=captured_at,
            recording_state=recording_state,
            checkpoint_reason=checkpoint_reason,
            segments=tuple(segments),
            capture_ended_at=capture_ended_at,
        )

    def as_dict(self) -> dict[str, object]:
        value: dict[str, object] = {
            "identity": self.identity.as_dict(),
            "captured_at": self.captured_at,
            "recording_state": self.recording_state,
            "checkpoint_reason": self.checkpoint_reason,
            "segments": [segment.as_dict() for segment in self.segments],
        }
        if self.capture_ended_at is not None:
            value["capture_ended_at"] = self.capture_ended_at
        return value


@dataclasses.dataclass(frozen=True)
class NoteDocument:
    identity: NoteIdentity
    update: NoteUpdate

    def as_dict(self) -> dict[str, object]:
        return self.update.as_dict()


def validate_note_id(value: str) -> tuple[str, int]:
    match = _NOTE_ID_RE.fullmatch(value)
    if not match:
        raise NoteContractError(f"invalid unpadded note ID: {value!r}")
    return match.group("prefix"), int(match.group("number"))


def validate_timestamp(value: str, label: str) -> None:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise NoteContractError(f"{label} is not RFC 3339: {value!r}") from error
    if parsed.tzinfo is None:
        raise NoteContractError(f"{label} must include a UTC offset")


def render_note_document(document: NoteDocument) -> bytes:
    identity = document.identity
    update = document.update
    if update.identity != identity:
        raise NoteContractError("note update identity changed")
    fields = [
        "---",
        f"note_schema_version: {NOTE_SCHEMA_VERSION}",
        f"id: {identity.note_id}",
        f"artifact_id: {identity.artifact_id}",
        f"project_id: {identity.project_id}",
        f"created_at: {identity.created_at}",
        f"capture_started_at: {identity.capture_started_at}",
        f"updated_at: {update.captured_at}",
        f"recording_state: {update.recording_state}",
        f"checkpoint_reason: {update.checkpoint_reason}",
        f"segment_count: {len(update.segments)}",
    ]
    if update.capture_ended_at is not None:
        fields.append(f"capture_ended_at: {update.capture_ended_at}")
    fields.extend(["---", "", "## Transcript", ""])
    for segment in update.segments:
        metadata = json.dumps(
            segment.metadata(), sort_keys=True, separators=(",", ":"), ensure_ascii=False
        )
        fields.extend([f"{_SEGMENT_MARKER}{metadata} -->", segment.text, ""])
    return ("\n".join(fields).rstrip("\n") + "\n").encode("utf-8")


def parse_note_document(content: bytes) -> NoteDocument:
    try:
        text = content.decode("utf-8")
    except UnicodeDecodeError as error:
        raise NoteContractError("note Markdown is not UTF-8") from error
    if "\x00" in text:
        raise NoteContractError("note Markdown contains NUL bytes")
    front, body = _split_front_matter(text)
    try:
        schema = int(front.get("note_schema_version", ""))
    except ValueError as error:
        raise NoteContractError("note_schema_version is invalid") from error
    if schema != NOTE_SCHEMA_VERSION:
        raise NoteContractError(
            f"unsupported note_schema_version {schema}; expected {NOTE_SCHEMA_VERSION}"
        )
    identity = NoteIdentity.from_mapping({
        "note_id": front.get("id"),
        "artifact_id": front.get("artifact_id"),
        "project_id": front.get("project_id"),
        "created_at": front.get("created_at"),
        "capture_started_at": front.get("capture_started_at"),
    })
    segments = _parse_segments(body)
    try:
        segment_count = int(front.get("segment_count", ""))
    except ValueError as error:
        raise NoteContractError("note segment_count is invalid") from error
    if segment_count != len(segments):
        raise NoteContractError("note segment_count does not match transcript segments")
    update = NoteUpdate.from_values(
        identity=identity,
        captured_at=front.get("updated_at", ""),
        recording_state=front.get("recording_state", ""),
        checkpoint_reason=front.get("checkpoint_reason", ""),
        raw_segments=[segment.as_dict() for segment in segments],
        capture_ended_at=front.get("capture_ended_at"),
    )
    return NoteDocument(identity=identity, update=update)


def decode_note_index(content: bytes, *, project_id: str) -> dict[str, dict[str, object]]:
    try:
        lines = content.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise NoteContractError("note index is not UTF-8") from error
    entries: dict[str, dict[str, object]] = {}
    note_ids: set[str] = set()
    for line_number, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError as error:
            raise NoteContractError(f"note index line {line_number} is invalid JSON: {error}") from error
        if not isinstance(value, dict):
            raise NoteContractError(f"note index line {line_number} is not an object")
        _validate_index_entry(value, project_id=project_id, line_number=line_number)
        artifact_id = str(value["artifact_id"])
        note_id = str(value["note_id"])
        if artifact_id in entries or note_id in note_ids:
            raise NoteContractError("note index has duplicate note or artifact identity")
        entries[artifact_id] = value
        note_ids.add(note_id)
    return entries


def encode_note_index(entries: Mapping[str, Mapping[str, object]], *, project_id: str) -> bytes:
    ordered = sorted(
        entries.values(),
        key=lambda entry: (*validate_note_id(str(entry.get("note_id") or "")), str(entry.get("artifact_id") or "")),
    )
    lines = []
    for line_number, entry in enumerate(ordered, 1):
        value = dict(entry)
        _validate_index_entry(value, project_id=project_id, line_number=line_number)
        lines.append(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
    return (("\n".join(lines) + "\n") if lines else "").encode("utf-8")


def _split_front_matter(text: str) -> tuple[dict[str, str], str]:
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        raise NoteContractError("note Markdown must have YAML front matter")
    try:
        closing = next(index for index, line in enumerate(lines[1:], 1) if line.strip() == "---")
    except StopIteration as error:
        raise NoteContractError("note Markdown front matter is not closed") from error
    front: dict[str, str] = {}
    for line in lines[1:closing]:
        key, separator, value = line.partition(":")
        if separator:
            front[key.strip()] = value.strip().strip("\"'")
    body = "\n".join(lines[closing + 1 :]).strip("\n")
    return front, body


def _parse_segments(body: str) -> tuple[NoteSegment, ...]:
    header = "## Transcript"
    if not body.startswith(header):
        raise NoteContractError("note Markdown has no Transcript section")
    transcript = body[len(header) :].strip("\n")
    if not transcript:
        return ()
    matches = list(_SEGMENT_RE.finditer(transcript))
    if not matches or transcript[: matches[0].start()].strip():
        raise NoteContractError("note transcript contains content outside typed segments")
    segments = []
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(transcript)
        raw_text = transcript[match.end() : end].strip("\n")
        try:
            metadata = json.loads(match.group(1))
        except json.JSONDecodeError as error:
            raise NoteContractError(f"note segment metadata is invalid JSON: {error}") from error
        if not isinstance(metadata, dict):
            raise NoteContractError("note segment metadata must be an object")
        segments.append(NoteSegment.from_mapping({**metadata, "text": raw_text}))
    return tuple(segments)


def _validate_index_entry(value: Mapping[str, object], *, project_id: str, line_number: int) -> None:
    if value.get("schema_version") != NOTE_INDEX_SCHEMA_VERSION:
        raise NoteContractError(f"note index line {line_number} has unsupported schema")
    note_id = str(value.get("note_id") or "")
    validate_note_id(note_id)
    artifact_id = str(value.get("artifact_id") or "")
    if not _ARTIFACT_ID_RE.fullmatch(artifact_id):
        raise NoteContractError("note index artifact_id is invalid")
    if value.get("project_id") != project_id:
        raise NoteContractError("note index project_id does not match the artifact store")
    if value.get("path") != f".orchestrator/notes/{note_id}.md":
        raise NoteContractError("note index path disagrees with note_id")
    validate_timestamp(str(value.get("created_at") or ""), "note index created_at")
    validate_timestamp(str(value.get("updated_at") or ""), "note index updated_at")
    if value.get("recording_state") not in NOTE_RECORDING_STATES:
        raise NoteContractError("note index recording_state is invalid")
    count = value.get("segment_count")
    if not isinstance(count, int) or isinstance(count, bool) or count < 0:
        raise NoteContractError("note index segment_count is invalid")
    if not isinstance(value.get("materialized"), bool):
        raise NoteContractError("note index materialized must be Boolean")
    for key in ("creation_event_id", "last_event_id"):
        if not _SAFE_ID_RE.fullmatch(str(value.get(key) or "")):
            raise NoteContractError(f"note index {key} is invalid")
    if not _DIGEST_RE.fullmatch(str(value.get("creation_request_sha256") or "")):
        raise NoteContractError("note index creation_request_sha256 is invalid")
    if value.get("materialized") is False:
        validate_timestamp(str(value.get("archived_at") or ""), "note index archived_at")
        if not _OBJECT_ID_RE.fullmatch(str(value.get("source_commit") or "")):
            raise NoteContractError("archived note source_commit is invalid")
        if not _OBJECT_ID_RE.fullmatch(str(value.get("source_blob") or "")):
            raise NoteContractError("archived note source_blob is invalid")


def _optional_nonnegative_int(value: object, label: str) -> int | None:
    if value is None:
        return None
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise NoteContractError(f"{label} must be a nonnegative integer")
    return value


__all__ = [
    "NOTE_CHECKPOINT_REASONS",
    "NOTE_INDEX_SCHEMA_VERSION",
    "NOTE_MAX_BYTES",
    "NOTE_RECORDING_STATES",
    "NOTE_SCHEMA_VERSION",
    "NoteContractError",
    "NoteDocument",
    "NoteIdentity",
    "NoteSegment",
    "NoteUpdate",
    "decode_note_index",
    "encode_note_index",
    "parse_note_document",
    "render_note_document",
    "validate_note_id",
    "validate_timestamp",
]
