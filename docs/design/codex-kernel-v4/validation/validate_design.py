#!/usr/bin/env python3
"""Read-only static validator for the CC Pocket Codex Kernel v4 design."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import sqlite3
import subprocess
import sys
import tempfile
import urllib.parse
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, Sequence


REPORT_FORMAT_VERSION = 1
PASS = "PASS"
FAIL = "FAIL"
NOT_RUN = "NOT_RUN"
MISSING = "FAIL_MISSING_ARTIFACT"

CANONICAL_SOURCE_PARTITION = (
    "bridgeIdentityId",
    "bridgeInstanceId",
    "codexSourceId",
)
CANONICAL_OPERATION_KEY = ("SourcePartition", "operationId")

FIXED_TABLE_SHAPES = {
    "matrices/BASELINE-DISPOSITION.csv": (30, 10),
    "matrices/USER-DECISION-REQUIRED.csv": (9, 8),
    "drafts/P1-IDENTITY-RECEIVE-MATRIX.csv": (37, 22),
    "drafts/P1-OPERATION-STATE-MATRIX.csv": (38, 24),
    "drafts/K-CAPABILITY-COMPLETION.csv": (26, 19),
    "drafts/P2-CAPABILITY-P001-P013.csv": (13, 17),
    "drafts/P2-CAPABILITY-P014-P026.csv": (13, 14),
    "drafts/SOURCE-REUSE-DISPOSITION.csv": (52, 9),
    "drafts/AUDIT-COVERAGE-CLOSURE.csv": (112, 9),
    "drafts/EXPERIMENT-AND-GATE-MATRIX.csv": (28, 12),
}

SOURCE_PATH_RE = re.compile(
    r"(?<![\w.-])((?:packages|apps)/[A-Za-z0-9_.+/@-]+"
    r"(?:/[A-Za-z0-9_.+@-]+)*|decisions\.md|THIRD_PARTY_NOTICES\.md)"
)
MARKDOWN_LINK_RE = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
FORBIDDEN_ACTOR_ALIASES = (
    "source_device_id",
    "claimantId",
    "deviceId",
    "faceIdPassed",
    "authenticated=true",
)
FORBIDDEN_WRITER_ALIASES = (
    "CanonicalProjectionWriter",
    "ReplicaApplyWriter",
    "CanonicalHistoryWriter",
    "EphemeralChildRegistry",
)

ALLOW_CONTEXT = (
    "delete",
    "replace",
    "remove",
    "rewrite",
    "reject",
    "forbid",
    "forbidden",
    "not_implemented",
    "no_import",
    "no_runtime",
    "unreachable",
    "fail",
    "fail closed",
    "fail-closed",
    "must not",
    "do not",
    "does not",
    "cannot",
    "never",
    "without",
    "evidence",
    "historical",
    "original",
    "donor",
    "source path",
    "source `",
    "alias",
    "allowed only",
    "zero reachable",
    "user decision",
    "current",
    "old",
    "competing",
    "parallel",
    "client boolean",
    "actor_field_forbidden",
    "amend",
    "quarantin",
    "deprecated",
    "删除",
    "替换",
    "拒绝",
    "禁止",
    "不得",
    "不能",
    "不再",
    "不进入",
    "不建立",
    "不保留",
    "不恢复",
    "不信任",
    "不接受",
    "不读取",
    "不读",
    "不可达",
    "只留",
    "隔离",
    "证据",
    "历史",
    "原始",
    "原提案",
    "现有",
    "当前源码",
    "别名",
    "统一回",
    "不另立",
    "无 ",
    "无`",
    "停止",
    "关闭",
    "明确禁止",
    "故意失败",
    "当前",
    "不是",
    "不允许",
    "不重新",
    "决定",
)

LEGACY_MARKER_RE = re.compile(r"\b(?:V2|Mirror|Claude|legacy|Legacy)\b")
FT_BAD_RE = re.compile(
    r"\b(?:FT[-_]?[23]|file[- ]transfer\s+v[23])\b", re.IGNORECASE
)

SQL_FILE_IO_RE = re.compile(
    r"\b(?:ATTACH|DETACH)\b|\bVACUUM\s+INTO\b|"
    r"\bCREATE\s+VIRTUAL\s+TABLE\b|"
    r"\b(?:load_extension|readfile|writefile)\s*\(",
    re.IGNORECASE,
)

JSON_SCHEMA_TYPES = {
    "null",
    "boolean",
    "object",
    "array",
    "number",
    "integer",
    "string",
}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def stable_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def normalize_tuple(raw: str) -> tuple[str, ...]:
    return tuple(part.strip().strip("` ") for part in raw.split(",") if part.strip())


def expand_id_sequence(parts: Sequence[Mapping[str, Any]]) -> list[str]:
    result: list[str] = []
    for part in parts:
        prefix = str(part["prefix"])
        start = int(part["start"])
        end = int(part["end"])
        width = int(part.get("width", 0))
        excluded = {int(value) for value in part.get("exclude", [])}
        for number in range(start, end + 1):
            if number in excluded:
                continue
            rendered = f"{number:0{width}d}" if width else str(number)
            result.append(f"{prefix}{rendered}")
    return result


def fixed_id_sequence(path: str) -> list[str]:
    simple = {
        "matrices/BASELINE-DISPOSITION.csv": [
            f"B-{number:03d}" for number in range(1, 31)
        ],
        "matrices/USER-DECISION-REQUIRED.csv": [
            f"U-{number:03d}" for number in range(1, 10)
        ],
        "drafts/P1-OPERATION-STATE-MATRIX.csv": [
            f"OP-{number:03d}" for number in range(1, 40) if number != 7
        ],
        "drafts/K-CAPABILITY-COMPLETION.csv": [
            f"K-{number:03d}" for number in range(1, 27)
        ],
        "drafts/P2-CAPABILITY-P001-P013.csv": [
            f"P-{number:03d}" for number in range(1, 14)
        ],
        "drafts/P2-CAPABILITY-P014-P026.csv": [
            f"P-{number:03d}" for number in range(14, 27)
        ],
        "drafts/SOURCE-REUSE-DISPOSITION.csv": [
            *[f"K-{number:03d}" for number in range(1, 27)],
            *[f"P-{number:03d}" for number in range(1, 27)],
        ],
        "drafts/EXPERIMENT-AND-GATE-MATRIX.csv": [
            *[f"H{number:02d}" for number in range(0, 19)],
            *[f"D{number:02d}" for number in range(0, 9)],
        ],
    }
    if path in simple:
        return simple[path]
    if path == "drafts/P1-IDENTITY-RECEIVE-MATRIX.csv":
        return [
            *[f"P1-ID-{number:03d}" for number in range(1, 10)],
            *[f"P1-FN-{number:03d}" for number in range(1, 5)],
            *[f"P1-RD-{number:03d}" for number in range(1, 6)],
            *[f"P1-CA-{number:03d}" for number in range(1, 7)],
            *[f"P1-LV-{number:03d}" for number in range(1, 4)],
            *[f"P1-WR-{number:03d}" for number in range(1, 4)],
            *[f"P1-CR-{number:03d}" for number in range(1, 3)],
            *[f"P1-DEL-{number:03d}" for number in range(1, 4)],
            *[f"P1-UD-{number:03d}" for number in range(6, 8)],
        ]
    if path == "drafts/AUDIT-COVERAGE-CLOSURE.csv":
        return [
            *[f"P0-{number:02d}" for number in range(1, 16)],
            *[f"P1-{number:02d}" for number in range(1, 11)],
            *[f"K-{number:03d}" for number in range(1, 27)],
            *[f"P-{number:03d}" for number in range(1, 27)],
            *[f"D-{number:03d}" for number in range(1, 13)],
            *[f"U-{number:03d}" for number in range(1, 10)],
            *[f"UNK-{number:03d}" for number in range(1, 15)],
        ]
    return []


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


def parse_json_file(path: Path) -> Any:
    with path.open("r", encoding="utf-8-sig") as handle:
        return json.load(handle)


class ValidationResult:
    def __init__(self, root: Path, design_root: Path, mode: str, report_path: Path):
        self.root = root
        self.design_root = design_root
        self.mode = mode
        self.report_path = report_path
        self.checks: list[dict[str, Any]] = []
        self.errors: list[dict[str, str]] = []
        self.head: str | None = None
        self.tree: str | None = None

    def error(
        self,
        check_id: str,
        code: str,
        message: str,
        artifact: str = "",
    ) -> None:
        self.errors.append(
            {
                "artifact": artifact,
                "check": check_id,
                "code": code,
                "message": message,
            }
        )

    def run(
        self,
        check_id: str,
        callback: Callable[[str], Mapping[str, Any] | None],
    ) -> bool:
        before = len(self.errors)
        try:
            details = dict(callback(check_id) or {})
        except Exception as exc:  # fail closed with a stable public error type
            self.error(
                check_id,
                "FAIL_VALIDATOR_EXCEPTION",
                f"{type(exc).__name__}: {exc}",
            )
            details = {}
        failed = len(self.errors) != before
        self.checks.append(
            {"details": details, "id": check_id, "status": FAIL if failed else PASS}
        )
        return not failed

    def not_run(self, check_id: str, reason: str) -> None:
        self.checks.append(
            {"details": {"reason": reason}, "id": check_id, "status": NOT_RUN}
        )

    def document(self, artifact_hashes: Mapping[str, Mapping[str, Any]]) -> dict[str, Any]:
        errors = sorted(
            self.errors,
            key=lambda item: (
                item["check"],
                item["code"],
                item["artifact"],
                item["message"],
            ),
        )
        overall = FAIL if errors else PASS
        document = {
            "artifact_hashes": dict(sorted(artifact_hashes.items())),
            "checks": self.checks,
            "design_root": str(self.design_root),
            "errors": errors,
            "git": {"head": self.head, "tree": self.tree},
            "mode": self.mode,
            "overall_status": overall,
            "report_format_version": REPORT_FORMAT_VERSION,
            "root": str(self.root),
        }
        document["validation_digest"] = hashlib.sha256(
            stable_json(document).encode("utf-8")
        ).hexdigest()
        return document


def load_inventory(
    result: ValidationResult, check_id: str
) -> tuple[dict[str, Any] | None, Mapping[str, Any]]:
    inventory_path = result.design_root / "validation/expected-inventory.json"
    if not inventory_path.is_file():
        result.error(
            check_id,
            MISSING,
            "required validator inventory is missing",
            "validation/expected-inventory.json",
        )
        return None, {"loaded": False}
    try:
        inventory = parse_json_file(inventory_path)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        result.error(
            check_id,
            "FAIL_INVALID_INVENTORY",
            f"inventory JSON cannot be parsed: {exc}",
            "validation/expected-inventory.json",
        )
        return None, {"loaded": False}
    if not isinstance(inventory, dict) or inventory.get("format_version") != 1:
        result.error(
            check_id,
            "FAIL_INVALID_INVENTORY",
            "inventory must be an object with format_version=1",
            "validation/expected-inventory.json",
        )
        return None, {"loaded": False}
    expected_design_dir = inventory.get("design_directory")
    if expected_design_dir != "docs/design/codex-kernel-v4":
        result.error(
            check_id,
            "FAIL_INVALID_INVENTORY",
            "design_directory must remain docs/design/codex-kernel-v4",
            "validation/expected-inventory.json",
        )
    tables = inventory.get("csv_tables")
    if not isinstance(tables, list):
        result.error(
            check_id,
            "FAIL_INVALID_INVENTORY",
            "csv_tables must be an array",
            "validation/expected-inventory.json",
        )
        return inventory, {"loaded": True, "format_version": 1}
    configured = {
        str(table.get("path")): table for table in tables if isinstance(table, dict)
    }
    for path, (fixed_rows, fixed_min_columns) in FIXED_TABLE_SHAPES.items():
        table = configured.get(path)
        if table is None:
            result.error(
                check_id,
                "FAIL_INVALID_INVENTORY",
                f"fixed CSV contract is missing: {path}",
                "validation/expected-inventory.json",
            )
            continue
        try:
            configured_rows = int(table.get("row_count", -1))
            configured_min_columns = int(table.get("min_columns", -1))
            configured_ids = expand_id_sequence(table.get("id_sequence", []))
        except (KeyError, TypeError, ValueError) as exc:
            result.error(
                check_id,
                "FAIL_INVALID_INVENTORY",
                f"invalid fixed CSV contract {path}: {exc}",
                "validation/expected-inventory.json",
            )
            continue
        if configured_rows != fixed_rows or configured_min_columns < fixed_min_columns:
            result.error(
                check_id,
                "FAIL_INVALID_INVENTORY",
                f"{path} must keep {fixed_rows} rows and at least {fixed_min_columns} columns",
                "validation/expected-inventory.json",
            )
        if configured_ids != fixed_id_sequence(path):
            result.error(
                check_id,
                "FAIL_INVALID_INVENTORY",
                f"{path} fixed ID sequence was weakened or changed",
                "validation/expected-inventory.json",
            )
    return inventory, {"format_version": 1, "loaded": True}


def git_identity(result: ValidationResult, check_id: str) -> Mapping[str, Any]:
    command = ["git", "-C", str(result.root), "rev-parse"]
    try:
        top = subprocess.run(
            command + ["--show-toplevel"],
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        ).stdout.strip()
        if Path(top).resolve() != result.root:
            raise ValueError(f"root is inside a different Git top-level: {top}")
        result.head = subprocess.run(
            command + ["HEAD"],
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        ).stdout.strip()
        result.tree = subprocess.run(
            command + ["HEAD^{tree}"],
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        ).stdout.strip()
    except (FileNotFoundError, subprocess.SubprocessError, ValueError) as exc:
        raise RuntimeError(str(exc)) from exc
    return {"available": True, "head": result.head, "tree": result.tree}


def check_required_files(
    result: ValidationResult,
    check_id: str,
    relative_paths: Sequence[str],
) -> Mapping[str, Any]:
    present = 0
    for raw in relative_paths:
        relative = Path(raw)
        candidate = (result.design_root / relative).resolve(strict=False)
        if relative.is_absolute() or not is_within(candidate, result.design_root):
            result.error(
                check_id,
                "FAIL_UNSAFE_INVENTORY_PATH",
                "inventory path escapes the design root",
                raw,
            )
            continue
        path = result.design_root / relative
        if not path.exists():
            result.error(check_id, MISSING, "required artifact is missing", raw)
        elif path.is_symlink() or not path.is_file():
            result.error(
                check_id,
                "FAIL_INVALID_ARTIFACT_TYPE",
                "required artifact must be a regular non-symlink file",
                raw,
            )
        elif path.stat().st_size == 0:
            result.error(
                check_id,
                "FAIL_EMPTY_ARTIFACT",
                "required artifact is empty",
                raw,
            )
        else:
            present += 1
    return {"present": present, "required": len(relative_paths)}


def validate_csv_table(path: Path, config: Mapping[str, Any]) -> list[dict[str, str]]:
    errors: list[dict[str, str]] = []

    def add(code: str, message: str) -> None:
        errors.append({"code": code, "message": message})

    if not path.is_file():
        add(MISSING, "CSV artifact is missing")
        return errors
    try:
        with path.open("r", encoding="utf-8-sig", newline="") as handle:
            raw_rows = list(csv.reader(handle, strict=True))
    except (OSError, UnicodeError, csv.Error) as exc:
        add("FAIL_CSV_PARSE", f"CSV parse failed: {exc}")
        return errors
    if not raw_rows:
        add("FAIL_CSV_EMPTY", "CSV contains no header")
        return errors

    header = raw_rows[0]
    if any(not value.strip() for value in header):
        add("FAIL_CSV_BLANK_HEADER", "CSV header contains a blank name")
    if len(set(header)) != len(header):
        add("FAIL_CSV_DUPLICATE_HEADER", "CSV header names are not unique")

    minimum_columns = int(config.get("min_columns", 0))
    if len(header) < minimum_columns:
        add(
            "FAIL_CSV_COLUMN_COUNT",
            f"CSV has {len(header)} columns; expected at least {minimum_columns}",
        )
    required_columns = [str(value) for value in config.get("required_columns", [])]
    missing_columns = [name for name in required_columns if name not in header]
    if missing_columns:
        add(
            "FAIL_CSV_REQUIRED_COLUMNS",
            f"missing required columns: {', '.join(missing_columns)}",
        )

    rows = raw_rows[1:]
    expected_rows = int(config.get("row_count", -1))
    if expected_rows >= 0 and len(rows) != expected_rows:
        add(
            "FAIL_CSV_ROW_COUNT",
            f"CSV has {len(rows)} rows; expected {expected_rows}",
        )

    for line_number, row in enumerate(rows, 2):
        if len(row) != len(header):
            add(
                "FAIL_CSV_ROW_WIDTH",
                f"row {line_number} has {len(row)} cells; header has {len(header)}",
            )
            continue
        for column_index, value in enumerate(row):
            if not value.strip():
                column = header[column_index] or f"column_{column_index + 1}"
                add(
                    "FAIL_CSV_BLANK_CELL",
                    f"row {line_number} column {column} is blank",
                )

    id_column = str(config.get("id_column", ""))
    if id_column and id_column in header:
        index = header.index(id_column)
        ids = [row[index] for row in rows if len(row) == len(header)]
        if len(set(ids)) != len(ids):
            add("FAIL_CSV_DUPLICATE_ID", f"{id_column} values are not unique")
        expected_ids = expand_id_sequence(config.get("id_sequence", []))
        if expected_ids and ids != expected_ids:
            add(
                "FAIL_CSV_ID_SEQUENCE",
                f"{id_column} sequence differs from the fixed inventory",
            )
    elif id_column:
        add("FAIL_CSV_ID_COLUMN", f"ID column {id_column} is missing")
    return errors


def check_csv_tables(
    result: ValidationResult,
    check_id: str,
    tables: Sequence[Mapping[str, Any]],
) -> Mapping[str, Any]:
    rows_checked = 0
    for config in tables:
        relative = str(config["path"])
        path = result.design_root / relative
        for error in validate_csv_table(path, config):
            result.error(check_id, error["code"], error["message"], relative)
        rows_checked += int(config.get("row_count", 0))
    return {"rows_expected": rows_checked, "tables": len(tables)}


def extract_source_paths(value: str) -> list[str]:
    return sorted(set(match.group(1).rstrip(".:") for match in SOURCE_PATH_RE.finditer(value)))


def check_source_references(
    result: ValidationResult,
    check_id: str,
    reference_columns: Mapping[str, Sequence[str]],
) -> Mapping[str, Any]:
    references: set[str] = set()
    for relative, columns in sorted(reference_columns.items()):
        path = result.design_root / relative
        if not path.is_file():
            result.error(check_id, MISSING, "source-reference CSV is missing", relative)
            continue
        try:
            with path.open("r", encoding="utf-8-sig", newline="") as handle:
                rows = list(csv.DictReader(handle, strict=True))
        except (OSError, UnicodeError, csv.Error) as exc:
            result.error(
                check_id,
                "FAIL_CSV_PARSE",
                f"cannot parse source-reference CSV: {exc}",
                relative,
            )
            continue
        available = set(rows[0]) if rows else set()
        for column in columns:
            if column not in available:
                result.error(
                    check_id,
                    "FAIL_SOURCE_REFERENCE_COLUMN",
                    f"source-reference column is missing: {column}",
                    relative,
                )
                continue
            for row in rows:
                references.update(extract_source_paths(row.get(column, "")))

    for reference in sorted(references):
        relative = Path(reference)
        candidate = (result.root / relative).resolve(strict=False)
        if relative.is_absolute() or ".." in relative.parts or not is_within(candidate, result.root):
            result.error(
                check_id,
                "FAIL_SOURCE_REFERENCE_ESCAPE",
                "source reference escapes repository root",
                reference,
            )
        elif not (result.root / relative).exists():
            result.error(
                check_id,
                "FAIL_SOURCE_REFERENCE_MISSING",
                "referenced current source/test path does not exist",
                reference,
            )
    if not references:
        result.error(
            check_id,
            "FAIL_SOURCE_REFERENCE_EMPTY",
            "no current source/test paths were extracted",
        )
    return {"references": len(references)}


def parse_markdown_target(raw: str) -> str:
    value = raw.strip()
    if value.startswith("<") and ">" in value:
        return value[1 : value.index(">")]
    if re.search(r"\s+[\"']", value):
        value = re.split(r"\s+[\"']", value, maxsplit=1)[0]
    return value


def check_markdown_references(
    result: ValidationResult, check_id: str
) -> Mapping[str, Any]:
    count = 0
    for path in sorted(result.design_root.rglob("*.md")):
        if path.is_symlink() or not path.is_file():
            continue
        relative_doc = path.relative_to(result.design_root).as_posix()
        for line_number, line in enumerate(read_text(path).splitlines(), 1):
            for match in MARKDOWN_LINK_RE.finditer(line):
                target = parse_markdown_target(match.group(1))
                if not target or target.startswith(("#", "http://", "https://", "mailto:")):
                    continue
                target_path = urllib.parse.unquote(target.split("#", 1)[0])
                if not target_path:
                    continue
                count += 1
                if target_path.startswith("/"):
                    candidate = Path(target_path).resolve(strict=False)
                else:
                    candidate = (path.parent / target_path).resolve(strict=False)
                artifact = f"{relative_doc}:{line_number}"
                if not is_within(candidate, result.root):
                    result.error(
                        check_id,
                        "FAIL_MARKDOWN_REFERENCE_ESCAPE",
                        f"Markdown link escapes repository root: {target}",
                        artifact,
                    )
                elif not candidate.exists():
                    result.error(
                        check_id,
                        "FAIL_MARKDOWN_REFERENCE_MISSING",
                        f"Markdown link target does not exist: {target}",
                        artifact,
                    )
    return {"local_links": count}


def semantic_files(design_root: Path) -> list[Path]:
    paths: list[Path] = []
    for pattern in ("*.md", "*.csv", "*.json", "*.sql"):
        for path in design_root.rglob(pattern):
            relative = path.relative_to(design_root)
            if relative.parts and relative.parts[0] == "validation":
                continue
            if path.is_file() and not path.is_symlink():
                paths.append(path)
    return sorted(set(paths))


def identity_errors(text: str) -> list[dict[str, str]]:
    errors: list[dict[str, str]] = []
    source_re = re.compile(
        r"\bSourcePartition\b\s*(?:(?:is\s+exactly|fixed\s+as)\s*)?=\s*\(([^)]*)\)",
        re.IGNORECASE,
    )
    operation_re = re.compile(
        r"\bOperationKey\b\s*=\s*\(([^)]*)\)", re.IGNORECASE
    )
    for match in source_re.finditer(text):
        actual = normalize_tuple(match.group(1))
        if actual != CANONICAL_SOURCE_PARTITION:
            errors.append(
                {
                    "code": "FAIL_SOURCE_PARTITION",
                    "message": f"SourcePartition definition is {actual!r}",
                }
            )
    for match in operation_re.finditer(text):
        actual = normalize_tuple(match.group(1))
        if actual != CANONICAL_OPERATION_KEY:
            errors.append(
                {
                    "code": "FAIL_OPERATION_KEY",
                    "message": f"OperationKey definition is {actual!r}",
                }
            )
    return errors


def check_identity_contracts(
    result: ValidationResult, check_id: str
) -> Mapping[str, Any]:
    source_definitions = 0
    operation_definitions = 0
    source_re = re.compile(r"\bSourcePartition\b[^\n=]{0,32}=\s*\(", re.IGNORECASE)
    operation_re = re.compile(r"\bOperationKey\b\s*=\s*\(", re.IGNORECASE)
    for path in semantic_files(result.design_root):
        relative = path.relative_to(result.design_root).as_posix()
        text = read_text(path)
        source_definitions += len(source_re.findall(text))
        operation_definitions += len(operation_re.findall(text))
        for error in identity_errors(text):
            result.error(check_id, error["code"], error["message"], relative)
    if source_definitions == 0:
        result.error(
            check_id,
            "FAIL_SOURCE_PARTITION_MISSING",
            "no SourcePartition tuple definition was found",
        )
    if operation_definitions == 0:
        result.error(
            check_id,
            "FAIL_OPERATION_KEY_MISSING",
            "no OperationKey tuple definition was found",
        )
    return {
        "operation_key_definitions": operation_definitions,
        "source_partition_definitions": source_definitions,
    }


def line_has_allow_context(line: str) -> bool:
    lowered = line.lower()
    return any(marker.lower() in lowered for marker in ALLOW_CONTEXT)


def check_aliases(result: ValidationResult, check_id: str) -> Mapping[str, Any]:
    occurrences = 0
    needles = FORBIDDEN_ACTOR_ALIASES + FORBIDDEN_WRITER_ALIASES
    for path in semantic_files(result.design_root):
        relative = path.relative_to(result.design_root).as_posix()
        if path.suffix.lower() == ".csv":
            try:
                with path.open("r", encoding="utf-8-sig", newline="") as handle:
                    rows = list(csv.DictReader(handle, strict=True))
            except (OSError, UnicodeError, csv.Error):
                continue
            for row_index, row in enumerate(rows, 2):
                row_context = " ".join(str(value) for value in row.values())
                for column, value in row.items():
                    found = [
                        needle
                        for needle in needles
                        if needle.lower() in (value or "").lower()
                    ]
                    if not found:
                        continue
                    occurrences += len(found)
                    evidence_column = any(
                        marker in (column or "").lower()
                        for marker in (
                            "forbidden",
                            "evidence",
                            "source",
                            "disposition",
                            "reason",
                            "baseline",
                        )
                    )
                    if not evidence_column and not line_has_allow_context(row_context):
                        result.error(
                            check_id,
                            "FAIL_FORBIDDEN_ACTOR_WRITER_ALIAS",
                            f"alias lacks explicit rejection/evidence context: {', '.join(found)}",
                            f"{relative}:{row_index}:{column}",
                        )
            continue

        lines = read_text(path).splitlines()
        for index, line in enumerate(lines):
            found = [needle for needle in needles if needle.lower() in line.lower()]
            if not found:
                continue
            occurrences += len(found)
            context = " ".join(lines[max(0, index - 2) : min(len(lines), index + 3)])
            if not line_has_allow_context(context):
                result.error(
                    check_id,
                    "FAIL_FORBIDDEN_ACTOR_WRITER_ALIAS",
                    f"alias lacks explicit rejection/evidence context: {', '.join(found)}",
                    f"{relative}:{index + 1}",
                )
    return {"reviewed_occurrences": occurrences}


def check_legacy_markers(
    result: ValidationResult, check_id: str
) -> Mapping[str, Any]:
    occurrences = 0
    for path in semantic_files(result.design_root):
        relative = path.relative_to(result.design_root).as_posix()
        strict_contract = relative.startswith("contracts/")
        lines = read_text(path).splitlines()
        negative_section = False
        for line_number, line in enumerate(lines, 1):
            if path.suffix.lower() == ".md" and line.lstrip().startswith("#"):
                heading = line.lower()
                negative_section = any(
                    marker in heading
                    for marker in (
                        "故意失败",
                        "必须故意失败",
                        "negative vector",
                        "fault vector",
                    )
                )
            matches = sorted(set(match.group(0) for match in LEGACY_MARKER_RE.finditer(line)))
            if not matches:
                continue
            occurrences += len(matches)
            context = " ".join(
                lines[max(0, line_number - 4) : min(len(lines), line_number + 3)]
            )
            allowed = negative_section or line_has_allow_context(context)
            if strict_contract:
                lowered = line.lower()
                allowed = any(
                    marker in lowered
                    for marker in (
                        "not_implemented",
                        "delete",
                        "forbidden",
                        "unreachable",
                        "不可达",
                        "删除",
                    )
                )
            if not allowed:
                result.error(
                    check_id,
                    "FAIL_REACHABLE_LEGACY_MARKER",
                    f"marker lacks evidence/delete/unreachable context: {', '.join(matches)}",
                    f"{relative}:{line_number}",
                )
    return {"reviewed_occurrences": occurrences}


def check_phase2_candidate_binding(
    result: ValidationResult,
    check_id: str,
    phase2_files: Sequence[str],
) -> Mapping[str, Any]:
    scanned = 0
    for relative in phase2_files:
        path = result.design_root / relative
        if not path.is_file():
            result.error(check_id, MISSING, "Phase 2 artifact is missing", relative)
            continue
        scanned += 1
        for line_number, line in enumerate(read_text(path).splitlines(), 1):
            if "CANDIDATE_BINDING" in line:
                result.error(
                    check_id,
                    "FAIL_PHASE2_CANDIDATE_BINDING",
                    "CANDIDATE_BINDING is forbidden in Phase 2",
                    f"{relative}:{line_number}",
                )
    return {"files": scanned}


def quantity_to_bytes(number: str, unit: str) -> int:
    value = int(number.replace(",", "").replace("_", "").replace(" ", ""))
    normalized = unit.lower()
    if normalized == "kib":
        return value * 1024
    if normalized == "mib":
        return value * 1024 * 1024
    return value


def budget_errors(text: str, maximum: int = 65536) -> list[dict[str, str]]:
    errors: list[dict[str, str]] = []
    pattern = re.compile(
        r"(?i)\b(?:control(?:\s+(?:frame|envelope|policy|body))?|envelope)"
        r"(?:\s+(?:at\s+most|max(?:imum)?))?\s*(?:<=|=|:)?\s*"
        r"([0-9][0-9,_ ]*)\s*(KiB|MiB|B|bytes)\b"
    )
    for match in pattern.finditer(text):
        declared = quantity_to_bytes(match.group(1), match.group(2))
        if declared > maximum:
            errors.append(
                {
                    "code": "FAIL_CONTROL_BUDGET_OVERSIZE",
                    "message": f"declared control/envelope budget {declared} exceeds {maximum}",
                }
            )
    return errors


def check_budgets(
    result: ValidationResult,
    check_id: str,
    configured: Mapping[str, Any],
) -> Mapping[str, Any]:
    expected = {"envelope": 65536, "payload": 57344, "interaction_answer": 49152}
    actual = {key: int(configured.get(key, -1)) for key in expected}
    if actual != expected:
        result.error(
            check_id,
            "FAIL_BUDGET_INVENTORY",
            f"inventory budgets differ from fixed values: {actual}",
            "validation/expected-inventory.json",
        )

    declarations = 0
    for path in semantic_files(result.design_root):
        relative = path.relative_to(result.design_root).as_posix()
        text = read_text(path)
        for error in budget_errors(text, expected["envelope"]):
            result.error(check_id, error["code"], error["message"], relative)
        declarations += len(
            re.findall(r"(?i)(?:control|envelope)[^\n]{0,32}(?:KiB|bytes|\dB)", text)
        )

    authoritative_paths = (
        result.design_root / "PROCESS-LEDGER.md",
        result.design_root / "drafts/P1-OPERATIONS-INTERACTIONS-RELATIONS.md",
    )
    authoritative = "\n".join(
        read_text(path) for path in authoritative_paths if path.is_file()
    )
    spellings = {
        "envelope": ("65,536", "65536", "64 KiB", "64KiB"),
        "payload": ("57,344", "57344", "56 KiB", "56KiB"),
        "interaction_answer": ("49,152", "49152", "48 KiB", "48KiB"),
    }
    for name, variants in spellings.items():
        if not any(value in authoritative for value in variants):
            result.error(
                check_id,
                "FAIL_BUDGET_DECLARATION_MISSING",
                f"authoritative {name} budget declaration is missing",
            )
    return {"declarations_reviewed": declarations, **expected}


def check_ft_naming(result: ValidationResult, check_id: str) -> Mapping[str, Any]:
    occurrences = 0
    for path in semantic_files(result.design_root):
        relative = path.relative_to(result.design_root).as_posix()
        for line_number, line in enumerate(read_text(path).splitlines(), 1):
            matches = list(FT_BAD_RE.finditer(line))
            occurrences += len(matches)
            if matches:
                result.error(
                    check_id,
                    "FAIL_FILE_TRANSFER_NAMING",
                    "file-transfer generations must be named FT/2 or FT/3",
                    f"{relative}:{line_number}",
                )
    content_path = result.design_root / "05-CONTENT-AND-PRODUCT-OPERATIONS.md"
    if content_path.is_file():
        content = read_text(content_path)
        for required in ("FT/2", "FT/3"):
            if required not in content:
                result.error(
                    check_id,
                    "FAIL_FILE_TRANSFER_NAMING_MISSING",
                    f"required canonical name is missing: {required}",
                    "05-CONTENT-AND-PRODUCT-OPERATIONS.md",
                )
    else:
        result.error(
            check_id,
            MISSING,
            "content/operation design is missing",
            "05-CONTENT-AND-PRODUCT-OPERATIONS.md",
        )
    return {"forbidden_spellings": occurrences}


def selector_has_forbidden_scope(value: Any) -> bool:
    rendered = stable_json(value).lower()
    return bool(re.search(r"\b(?:generic|global|path|route)\b", rendered))


def check_r14_operation_preflight(
    result: ValidationResult, check_id: str
) -> Mapping[str, Any]:
    relative = "drafts/P1-OPERATION-STATE-MATRIX.csv"
    path = result.design_root / relative
    if not path.is_file():
        result.error(check_id, MISSING, "operation matrix is missing", relative)
        return {"operations": 0}
    try:
        with path.open("r", encoding="utf-8-sig", newline="") as handle:
            rows = list(csv.DictReader(handle, strict=True))
    except (OSError, UnicodeError, csv.Error) as exc:
        result.error(
            check_id,
            "FAIL_CSV_PARSE",
            f"operation matrix cannot be parsed: {exc}",
            relative,
        )
        return {"operations": 0}
    for row_index, row in enumerate(rows, 2):
        operation_id = row.get("mutation_id", f"row-{row_index}")
        lane = row.get("queue_lane", "")
        if selector_has_forbidden_scope(lane):
            result.error(
                check_id,
                "FAIL_R14_FORBIDDEN_LANE_SCOPE",
                f"{operation_id} uses generic/global/path/route lane: {lane}",
                f"{relative}:{row_index}",
            )
        replay = row.get("replay_policy", "")
        lowered = replay.lower()
        same_id = "same operationid" in lowered or "same id" in lowered
        dispatch_word = bool(re.search(r"\b(?:resend|redispatch|re-dispatch)\b", lowered))
        safe_lookup = any(
            marker in lowered
            for marker in (
                "admission",
                "lookup",
                "returns",
                "read-only",
                "never",
                "no automatic",
                "not ",
            )
        )
        if same_id and dispatch_word and not safe_lookup:
            result.error(
                check_id,
                "FAIL_R14_SAME_ID_REDISPATCH",
                f"{operation_id} describes same-ID resend/redispatch",
                f"{relative}:{row_index}",
            )
    return {"operations": len(rows)}


def check_r14_machine_contracts(
    result: ValidationResult, check_id: str
) -> Mapping[str, Any]:
    relative = "contracts/contract-registry.json"
    path = result.design_root / relative
    try:
        registry = parse_json_file(path)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        result.error(
            check_id,
            "FAIL_R14_REGISTRY_PARSE",
            f"machine registry cannot be parsed: {exc}",
            relative,
        )
        return {"operations": 0}
    operations = registry.get("operations") if isinstance(registry, dict) else None
    if not isinstance(operations, list) or not operations:
        result.error(
            check_id,
            "FAIL_R14_OPERATION_REGISTRY",
            "registry operations must be a nonempty array",
            relative,
        )
        return {"operations": 0}
    for index, operation in enumerate(operations):
        artifact = f"{relative}#operations/{index}"
        if not isinstance(operation, dict):
            result.error(
                check_id,
                "FAIL_R14_OPERATION_REGISTRY",
                "operation descriptor must be an object",
                artifact,
            )
            continue
        operation_id = operation.get("id", f"operation-{index}")
        for selector in ("queueLaneSelector", "executionConflictSelector"):
            if selector not in operation:
                result.error(
                    check_id,
                    "FAIL_R14_SELECTOR_MISSING",
                    f"{operation_id} is missing {selector}",
                    artifact,
                )
            elif selector_has_forbidden_scope(operation[selector]):
                result.error(
                    check_id,
                    "FAIL_R14_FORBIDDEN_LANE_SCOPE",
                    f"{operation_id} {selector} uses generic/global/path/route scope",
                    artifact,
                )
        rendered = stable_json(operation).lower()
        if re.search(
            r"same.{0,40}(?:operation)?id.{0,80}(?:resend|redispatch|re-dispatch).{0,40}dispatch",
            rendered,
        ) or "resend_dispatch" in rendered:
            result.error(
                check_id,
                "FAIL_R14_SAME_ID_REDISPATCH",
                f"{operation_id} describes same-ID resend dispatch",
                artifact,
            )
        if re.search(
            r"legacy.{0,80}upload.{0,80}fallback|upload.{0,80}legacy.{0,80}fallback",
            rendered,
        ):
            result.error(
                check_id,
                "FAIL_R14_LEGACY_UPLOAD_FALLBACK",
                f"{operation_id} registers a legacy upload mutation fallback",
                artifact,
            )
    return {"operations": len(operations), "selectors_per_operation": 2}


def final_missing_artifacts(
    design_root: Path, final_config: Mapping[str, Any]
) -> list[str]:
    missing: list[str] = []
    for relative in final_config.get("required_files", []):
        path = design_root / str(relative)
        if not path.is_file() or path.is_symlink() or path.stat().st_size == 0:
            missing.append(str(relative))
    for entry in final_config.get("required_globs", []):
        pattern = str(entry["pattern"])
        minimum = int(entry.get("minimum", 1))
        matches = [
            path
            for path in design_root.glob(pattern)
            if path.is_file() and not path.is_symlink() and path.stat().st_size > 0
        ]
        if len(matches) < minimum:
            missing.append(pattern)
    return sorted(missing)


def check_final_inventory(
    result: ValidationResult,
    check_id: str,
    final_config: Mapping[str, Any],
) -> Mapping[str, Any]:
    missing = final_missing_artifacts(result.design_root, final_config)
    for artifact in missing:
        result.error(
            check_id,
            MISSING,
            "required final artifact or glob is missing/empty",
            artifact,
        )
    return {
        "missing": len(missing),
        "required_files": len(final_config.get("required_files", [])),
        "required_globs": len(final_config.get("required_globs", [])),
    }


def registry_budget_value(budgets: Mapping[str, Any], names: Sequence[str]) -> Any:
    for name in names:
        if name in budgets:
            return budgets[name]
    return None


def check_contract_registry(
    result: ValidationResult,
    check_id: str,
    final_config: Mapping[str, Any],
) -> Mapping[str, Any]:
    relative = "contracts/contract-registry.json"
    path = result.design_root / relative
    try:
        registry = parse_json_file(path)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        result.error(
            check_id,
            "FAIL_CONTRACT_REGISTRY_PARSE",
            f"contract registry cannot be parsed: {exc}",
            relative,
        )
        return {"arrays": 0}
    if not isinstance(registry, dict):
        result.error(
            check_id,
            "FAIL_CONTRACT_REGISTRY_STRUCTURE",
            "contract registry must be a JSON object",
            relative,
        )
        return {"arrays": 0}
    required_keys = [str(value) for value in final_config.get("contract_registry_required_keys", [])]
    missing_keys = [key for key in required_keys if key not in registry]
    if missing_keys:
        result.error(
            check_id,
            "FAIL_CONTRACT_REGISTRY_KEYS",
            f"missing keys: {', '.join(missing_keys)}",
            relative,
        )
    if registry.get("status") != "USER_REVIEW_PENDING":
        result.error(
            check_id,
            "FAIL_CONTRACT_REGISTRY_STATUS",
            "final registry status must be USER_REVIEW_PENDING",
            relative,
        )

    source_partition = registry.get("sourcePartition")
    if isinstance(source_partition, dict):
        source_partition = source_partition.get("fields")
    if tuple(source_partition or ()) != CANONICAL_SOURCE_PARTITION:
        result.error(
            check_id,
            "FAIL_SOURCE_PARTITION",
            "registry sourcePartition must contain the canonical ordered triple",
            relative,
        )

    budgets = registry.get("budgets")
    if not isinstance(budgets, dict):
        result.error(
            check_id,
            "FAIL_CONTRACT_REGISTRY_BUDGETS",
            "registry budgets must be an object",
            relative,
        )
    else:
        values = {
            "envelope": registry_budget_value(budgets, ("envelope", "controlEnvelopeBytes")),
            "payload": registry_budget_value(budgets, ("payload", "generalPayloadBytes")),
            "interaction_answer": registry_budget_value(
                budgets, ("interaction_answer", "interactionAnswerBytes")
            ),
        }
        expected = {"envelope": 65536, "payload": 57344, "interaction_answer": 49152}
        if values != expected:
            result.error(
                check_id,
                "FAIL_CONTRACT_REGISTRY_BUDGETS",
                f"registry budgets differ from fixed values: {values}",
                relative,
            )

    arrays_checked = 0
    id_sets: dict[str, set[str]] = {}
    for key in final_config.get("contract_registry_id_arrays", []):
        value = registry.get(key)
        if not isinstance(value, list) or not value:
            result.error(
                check_id,
                "FAIL_CONTRACT_REGISTRY_ARRAY",
                f"{key} must be a nonempty array",
                relative,
            )
            continue
        arrays_checked += 1
        ids: list[str] = []
        for index, item in enumerate(value):
            if not isinstance(item, dict) or not isinstance(item.get("id"), str) or not item["id"].strip():
                result.error(
                    check_id,
                    "FAIL_CONTRACT_REGISTRY_ID",
                    f"{key}[{index}] must contain a nonblank string id",
                    relative,
                )
            else:
                ids.append(item["id"])
        if len(ids) != len(set(ids)):
            result.error(
                check_id,
                "FAIL_CONTRACT_REGISTRY_DUPLICATE_ID",
                f"{key} contains duplicate ids",
                relative,
            )
        id_sets[str(key)] = set(ids)

    for key, directory, suffix in (
        ("schemas", "contracts/schema", ".schema.json"),
        ("databases", "contracts/sql", ".sql"),
    ):
        base = (result.design_root / directory).resolve(strict=False)
        for index, item in enumerate(registry.get(key, [])):
            if not isinstance(item, dict) or not isinstance(item.get("path"), str):
                result.error(
                    check_id,
                    "FAIL_CONTRACT_REGISTRY_PATH",
                    f"{key}[{index}] must contain a path",
                    relative,
                )
                continue
            raw_path = item["path"]
            candidate = (
                (result.design_root / raw_path).resolve(strict=False)
                if raw_path.startswith("contracts/")
                else (base / raw_path).resolve(strict=False)
            )
            if (
                Path(raw_path).is_absolute()
                or ".." in Path(raw_path).parts
                or not is_within(candidate, base)
                or not candidate.is_file()
                or candidate.is_symlink()
                or not candidate.name.endswith(suffix)
            ):
                result.error(
                    check_id,
                    "FAIL_CONTRACT_REGISTRY_PATH",
                    f"{key}[{index}] path is missing, unsafe, or has wrong suffix: {raw_path}",
                    relative,
                )

    reference_targets = {
        "ownerId": "owners",
        "schemaId": "schemas",
        "requestSchemaId": "schemas",
        "resultSchemaId": "schemas",
        "errorId": "errors",
        "errorIds": "errors",
        "portId": "ports",
        "portIds": "ports",
        "capabilityId": "capabilities",
        "capabilityIds": "capabilities",
    }
    references_checked = 0

    def walk_references(node: Any, location: str) -> None:
        nonlocal references_checked
        if isinstance(node, dict):
            for key, value in node.items():
                target_name = reference_targets.get(key)
                if target_name is not None:
                    values = value if isinstance(value, list) else [value]
                    for referenced in values:
                        references_checked += 1
                        if (
                            not isinstance(referenced, str)
                            or referenced not in id_sets.get(target_name, set())
                        ):
                            result.error(
                                check_id,
                                "FAIL_CONTRACT_REGISTRY_REFERENCE",
                                f"{location}/{key} does not resolve in {target_name}: {referenced!r}",
                                relative,
                            )
                walk_references(value, f"{location}/{key}")
        elif isinstance(node, list):
            for index, value in enumerate(node):
                walk_references(value, f"{location}/{index}")

    for key in ("messages", "operations", "ports", "capabilities"):
        walk_references(registry.get(key, []), f"#/{key}")

    registered_negative = registry.get("sqlNegativeVectors")
    negative_ids: list[str] = []
    if isinstance(registered_negative, list):
        for item in registered_negative:
            if isinstance(item, str):
                negative_ids.append(item)
            elif isinstance(item, dict) and isinstance(item.get("id"), str):
                negative_ids.append(item["id"])
    if len(negative_ids) != len(set(negative_ids)) or not negative_ids:
        result.error(
            check_id,
            "FAIL_CONTRACT_REGISTRY_NEGATIVE_VECTORS",
            "sqlNegativeVectors must contain unique nonblank IDs",
            relative,
        )
    negative_path = result.design_root / "contracts/sql/negative-vectors.json"
    try:
        negative_document = parse_json_file(negative_path)
        file_negative_ids = {
            item["id"]
            for item in negative_document.get("vectors", [])
            if isinstance(item, dict) and isinstance(item.get("id"), str)
        }
    except (OSError, UnicodeError, json.JSONDecodeError, AttributeError):
        file_negative_ids = set()
    if set(negative_ids) != file_negative_ids:
        result.error(
            check_id,
            "FAIL_CONTRACT_REGISTRY_NEGATIVE_VECTORS",
            "sqlNegativeVectors IDs differ from negative-vectors.json",
            relative,
        )
    return {
        "arrays": arrays_checked,
        "references": references_checked,
        "required_keys": len(required_keys),
    }


def resolve_json_pointer(document: Any, fragment: str) -> bool:
    if fragment in ("", "#"):
        return True
    pointer = fragment[1:] if fragment.startswith("#") else fragment
    if not pointer.startswith("/"):
        return False
    current = document
    for raw in pointer[1:].split("/"):
        token = urllib.parse.unquote(raw).replace("~1", "/").replace("~0", "~")
        if isinstance(current, dict) and token in current:
            current = current[token]
        elif isinstance(current, list) and token.isdigit() and int(token) < len(current):
            current = current[int(token)]
        else:
            return False
    return True


def validate_schema_node(
    node: Any,
    path: Path,
    schema_root: Path,
    documents: Mapping[Path, Any],
    location: str,
    errors: list[str],
) -> None:
    if isinstance(node, bool):
        return
    if not isinstance(node, dict):
        errors.append(f"{location}: schema node must be object or boolean")
        return

    type_value = node.get("type")
    if type_value is not None:
        types = [type_value] if isinstance(type_value, str) else type_value
        if (
            not isinstance(types, list)
            or not types
            or any(not isinstance(value, str) or value not in JSON_SCHEMA_TYPES for value in types)
            or len(types) != len(set(types))
        ):
            errors.append(f"{location}/type: invalid JSON Schema type")

    properties = node.get("properties")
    if properties is not None and not isinstance(properties, dict):
        errors.append(f"{location}/properties: must be an object")
    elif isinstance(properties, dict):
        for key, child in properties.items():
            validate_schema_node(
                child, path, schema_root, documents, f"{location}/properties/{key}", errors
            )

    required = node.get("required")
    if required is not None:
        if (
            not isinstance(required, list)
            or any(not isinstance(value, str) or not value for value in required)
            or len(required) != len(set(required))
        ):
            errors.append(f"{location}/required: must be unique nonblank strings")

    for keyword in ("additionalProperties", "unevaluatedProperties", "items", "contains", "not"):
        if keyword in node:
            child = node[keyword]
            if not isinstance(child, (dict, bool)):
                errors.append(f"{location}/{keyword}: must be schema object or boolean")
            else:
                validate_schema_node(
                    child, path, schema_root, documents, f"{location}/{keyword}", errors
                )

    for keyword in ("$defs", "definitions", "patternProperties", "dependentSchemas"):
        if keyword in node:
            children = node[keyword]
            if not isinstance(children, dict):
                errors.append(f"{location}/{keyword}: must be an object")
            else:
                for key, child in children.items():
                    validate_schema_node(
                        child,
                        path,
                        schema_root,
                        documents,
                        f"{location}/{keyword}/{key}",
                        errors,
                    )

    for keyword in ("allOf", "anyOf", "oneOf", "prefixItems"):
        if keyword in node:
            children = node[keyword]
            if not isinstance(children, list) or not children:
                errors.append(f"{location}/{keyword}: must be a nonempty array")
            else:
                for index, child in enumerate(children):
                    validate_schema_node(
                        child,
                        path,
                        schema_root,
                        documents,
                        f"{location}/{keyword}/{index}",
                        errors,
                    )

    if "enum" in node:
        enum = node["enum"]
        if not isinstance(enum, list) or not enum:
            errors.append(f"{location}/enum: must be a nonempty array")
        elif len({stable_json(value) for value in enum}) != len(enum):
            errors.append(f"{location}/enum: values must be unique")

    integer_bounds = (
        "minLength",
        "maxLength",
        "minItems",
        "maxItems",
        "minProperties",
        "maxProperties",
    )
    for keyword in integer_bounds:
        if keyword in node:
            value = node[keyword]
            if isinstance(value, bool) or not isinstance(value, int) or value < 0:
                errors.append(f"{location}/{keyword}: must be a nonnegative integer")
    for minimum, maximum in (
        ("minLength", "maxLength"),
        ("minItems", "maxItems"),
        ("minProperties", "maxProperties"),
        ("minimum", "maximum"),
        ("exclusiveMinimum", "exclusiveMaximum"),
    ):
        if minimum in node and maximum in node:
            low, high = node[minimum], node[maximum]
            if (
                isinstance(low, (int, float))
                and not isinstance(low, bool)
                and isinstance(high, (int, float))
                and not isinstance(high, bool)
                and low > high
            ):
                errors.append(f"{location}: {minimum} exceeds {maximum}")
    if "pattern" in node:
        if not isinstance(node["pattern"], str):
            errors.append(f"{location}/pattern: must be a string")
        else:
            try:
                re.compile(node["pattern"])
            except re.error as exc:
                errors.append(f"{location}/pattern: invalid regex: {exc}")

    reference = node.get("$ref")
    if reference is not None:
        if not isinstance(reference, str) or not reference:
            errors.append(f"{location}/$ref: must be a nonblank string")
        elif reference.startswith(("http://", "https://")):
            errors.append(f"{location}/$ref: network references are forbidden")
        else:
            file_part, separator, fragment = reference.partition("#")
            target_path = path if not file_part else (path.parent / file_part).resolve(strict=False)
            if not is_within(target_path, schema_root):
                errors.append(f"{location}/$ref: reference escapes schema directory")
            elif target_path not in documents:
                errors.append(f"{location}/$ref: target schema does not exist")
            elif separator and not resolve_json_pointer(documents[target_path], f"#{fragment}"):
                errors.append(f"{location}/$ref: JSON pointer does not resolve")


def check_json_schemas(
    result: ValidationResult, check_id: str
) -> Mapping[str, Any]:
    schema_root = (result.design_root / "contracts/schema").resolve(strict=False)
    paths = sorted(
        path.resolve()
        for path in schema_root.glob("*.schema.json")
        if path.is_file() and not path.is_symlink()
    )
    documents: dict[Path, Any] = {}
    for path in paths:
        relative = path.relative_to(result.design_root).as_posix()
        try:
            documents[path] = parse_json_file(path)
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            result.error(
                check_id,
                "FAIL_JSON_SCHEMA_PARSE",
                f"schema cannot be parsed: {exc}",
                relative,
            )
    for path, document in sorted(documents.items(), key=lambda pair: str(pair[0])):
        relative = path.relative_to(result.design_root).as_posix()
        if not isinstance(document, dict):
            result.error(
                check_id,
                "FAIL_JSON_SCHEMA_STRUCTURE",
                "schema root must be an object",
                relative,
            )
            continue
        if not isinstance(document.get("$schema"), str) or not document["$schema"]:
            result.error(
                check_id,
                "FAIL_JSON_SCHEMA_STRUCTURE",
                "$schema must be a nonblank string",
                relative,
            )
        if not isinstance(document.get("$id"), str) or not document["$id"]:
            result.error(
                check_id,
                "FAIL_JSON_SCHEMA_STRUCTURE",
                "$id must be a nonblank string",
                relative,
            )
        if not any(key in document for key in ("type", "oneOf", "anyOf", "allOf")):
            result.error(
                check_id,
                "FAIL_JSON_SCHEMA_STRUCTURE",
                "schema needs type/oneOf/anyOf/allOf",
                relative,
            )
        structural_errors: list[str] = []
        validate_schema_node(
            document, path, schema_root, documents, "#", structural_errors
        )
        for message in structural_errors:
            result.error(
                check_id,
                "FAIL_JSON_SCHEMA_STRUCTURE",
                message,
                relative,
            )
    return {"schemas": len(paths)}


def ensure_safe_sql(sql: str) -> str | None:
    match = SQL_FILE_IO_RE.search(sql)
    return match.group(0) if match else None


def load_ddl(connection: sqlite3.Connection, paths: Sequence[Path]) -> None:
    connection.execute("PRAGMA foreign_keys=ON")
    connection.execute("PRAGMA temp_store=MEMORY")
    for path in paths:
        sql = read_text(path)
        unsafe = ensure_safe_sql(sql)
        if unsafe:
            raise ValueError(f"file-capable SQL is forbidden: {unsafe}")
        connection.executescript(sql)


def check_sqlite_ddl(
    result: ValidationResult, check_id: str
) -> Mapping[str, Any]:
    sql_root = result.design_root / "contracts/sql"
    paths = sorted(
        path for path in sql_root.glob("*.sql") if path.is_file() and not path.is_symlink()
    )
    for path in paths:
        relative = path.relative_to(result.design_root).as_posix()
        connection = sqlite3.connect(":memory:")
        try:
            load_ddl(connection, [path])
            foreign = connection.execute("PRAGMA foreign_key_check").fetchall()
            if foreign:
                result.error(
                    check_id,
                    "FAIL_SQLITE_FOREIGN_KEY_CHECK",
                    f"foreign_key_check returned {len(foreign)} rows",
                    relative,
                )
            quick = [row[0] for row in connection.execute("PRAGMA quick_check").fetchall()]
            if quick != ["ok"]:
                result.error(
                    check_id,
                    "FAIL_SQLITE_QUICK_CHECK",
                    f"quick_check returned {quick!r}",
                    relative,
                )
        except (OSError, UnicodeError, sqlite3.Error, ValueError) as exc:
            result.error(
                check_id,
                "FAIL_SQLITE_DDL_LOAD",
                f"fresh in-memory DDL load failed: {exc}",
                relative,
            )
        finally:
            connection.close()
    return {"ddl_files": len(paths), "database": ":memory:"}


def check_sql_negative_vectors(
    result: ValidationResult,
    check_id: str,
    final_config: Mapping[str, Any],
) -> Mapping[str, Any]:
    relative = "contracts/sql/negative-vectors.json"
    path = result.design_root / relative
    try:
        document = parse_json_file(path)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        result.error(
            check_id,
            "FAIL_SQL_NEGATIVE_REGISTRY_PARSE",
            f"negative-vector registry cannot be parsed: {exc}",
            relative,
        )
        return {"vectors": 0}
    if not isinstance(document, dict) or document.get("formatVersion") != 1:
        result.error(
            check_id,
            "FAIL_SQL_NEGATIVE_REGISTRY_STRUCTURE",
            "negative-vector registry needs formatVersion=1",
            relative,
        )
        return {"vectors": 0}
    vectors = document.get("vectors")
    if not isinstance(vectors, list) or not vectors:
        result.error(
            check_id,
            "FAIL_SQL_NEGATIVE_REGISTRY_STRUCTURE",
            "vectors must be a nonempty array",
            relative,
        )
        return {"vectors": 0}
    ids: list[str] = []
    sql_root = (result.design_root / "contracts/sql").resolve()
    for index, vector in enumerate(vectors):
        artifact = f"{relative}#vectors/{index}"
        if not isinstance(vector, dict):
            result.error(
                check_id,
                "FAIL_SQL_NEGATIVE_VECTOR_STRUCTURE",
                "vector must be an object",
                artifact,
            )
            continue
        vector_id = vector.get("id")
        ddl = vector.get("ddl")
        statement = vector.get("statement")
        expected_error = vector.get("expectedErrorContains")
        setup = vector.get("setupSql", "")
        if not isinstance(vector_id, str) or not vector_id.strip():
            result.error(
                check_id,
                "FAIL_SQL_NEGATIVE_VECTOR_STRUCTURE",
                "id must be a nonblank string",
                artifact,
            )
            continue
        ids.append(vector_id)
        if (
            not isinstance(ddl, list)
            or not ddl
            or any(not isinstance(value, str) or not value for value in ddl)
            or not isinstance(statement, str)
            or not statement.strip()
            or not isinstance(expected_error, str)
            or not expected_error
            or not isinstance(setup, str)
        ):
            result.error(
                check_id,
                "FAIL_SQL_NEGATIVE_VECTOR_STRUCTURE",
                "ddl, statement, expectedErrorContains, or setupSql is invalid",
                artifact,
            )
            continue
        ddl_paths: list[Path] = []
        unsafe_path = False
        for name in ddl:
            candidate = (sql_root / name).resolve(strict=False)
            if Path(name).is_absolute() or Path(name).name != name or not is_within(candidate, sql_root):
                result.error(
                    check_id,
                    "FAIL_SQL_NEGATIVE_DDL_PATH",
                    f"DDL name must be a basename inside contracts/sql: {name}",
                    artifact,
                )
                unsafe_path = True
            elif not candidate.is_file() or candidate.suffix != ".sql":
                result.error(
                    check_id,
                    MISSING,
                    f"negative vector DDL is missing: {name}",
                    artifact,
                )
                unsafe_path = True
            else:
                ddl_paths.append(candidate)
        unsafe_sql = ensure_safe_sql(setup + "\n" + statement)
        if unsafe_sql:
            result.error(
                check_id,
                "FAIL_SQL_FILE_IO",
                f"negative vector contains file-capable SQL: {unsafe_sql}",
                artifact,
            )
            unsafe_path = True
        if unsafe_path:
            continue
        connection = sqlite3.connect(":memory:")
        try:
            load_ddl(connection, ddl_paths)
            if setup.strip():
                connection.executescript(setup)
            try:
                connection.execute(statement)
                connection.commit()
            except sqlite3.Error as exc:
                if expected_error not in str(exc):
                    result.error(
                        check_id,
                        "FAIL_SQL_NEGATIVE_WRONG_ERROR",
                        f"{vector_id} raised {exc!s}, expected substring {expected_error!r}",
                        artifact,
                    )
            else:
                result.error(
                    check_id,
                    "FAIL_SQL_NEGATIVE_ACCEPTED",
                    f"{vector_id} statement unexpectedly succeeded",
                    artifact,
                )
        except (OSError, UnicodeError, sqlite3.Error, ValueError) as exc:
            result.error(
                check_id,
                "FAIL_SQL_NEGATIVE_SETUP",
                f"{vector_id} setup failed before the deliberate statement: {exc}",
                artifact,
            )
        finally:
            connection.close()
    if len(ids) != len(set(ids)):
        result.error(
            check_id,
            "FAIL_SQL_NEGATIVE_DUPLICATE_ID",
            "negative-vector ids are not unique",
            relative,
        )
    required_ids = {str(value) for value in final_config.get("negative_vector_required_ids", [])}
    missing_ids = sorted(required_ids - set(ids))
    if missing_ids:
        result.error(
            check_id,
            "FAIL_SQL_NEGATIVE_REQUIRED_IDS",
            f"missing required negative vectors: {', '.join(missing_ids)}",
            relative,
        )
    return {"required_ids": len(required_ids), "vectors": len(vectors)}


def check_final_matrices(
    result: ValidationResult,
    check_id: str,
    tables: Sequence[Mapping[str, Any]],
) -> Mapping[str, Any]:
    by_name = {Path(str(table["path"])).name: table for table in tables}
    final_tables: list[dict[str, Any]] = []
    for name in ("EXPERIMENT-AND-GATE-MATRIX.csv", "AUDIT-COVERAGE-CLOSURE.csv"):
        config = dict(by_name[name])
        config["path"] = f"matrices/{name}"
        final_tables.append(config)
    for config in final_tables:
        relative = str(config["path"])
        errors = validate_csv_table(result.design_root / relative, config)
        for error in errors:
            result.error(check_id, error["code"], error["message"], relative)

    risk_relative = "matrices/RISK_REGISTER.csv"
    risk_path = result.design_root / risk_relative
    try:
        with risk_path.open("r", encoding="utf-8-sig", newline="") as handle:
            raw_rows = list(csv.reader(handle, strict=True))
    except (OSError, UnicodeError, csv.Error) as exc:
        result.error(
            check_id,
            "FAIL_CSV_PARSE",
            f"risk register cannot be parsed: {exc}",
            risk_relative,
        )
        return {"matrices": len(final_tables) + 1}
    if not raw_rows:
        result.error(
            check_id,
            "FAIL_CSV_EMPTY",
            "risk register has no header",
            risk_relative,
        )
        return {"matrices": len(final_tables) + 1}
    header = raw_rows[0]
    rows = raw_rows[1:]
    if any(not value.strip() for value in header) or len(header) != len(set(header)):
        result.error(
            check_id,
            "FAIL_CSV_REQUIRED_COLUMNS",
            "risk register headers must be unique and nonblank",
            risk_relative,
        )
    semantic_columns = {
        "id": ("risk_id", "id"),
        "risk": ("risk",),
        "likelihood": ("likelihood",),
        "impact": ("impact",),
        "mitigation": ("mitigation",),
        "owner": ("owner", "owner_stage"),
        "evidence": ("evidence_gate", "evidence"),
        "rollback": ("rollback", "rollback_gate"),
    }
    selected: dict[str, str] = {}
    for semantic, aliases in semantic_columns.items():
        selected_name = next((name for name in aliases if name in header), None)
        if selected_name is None:
            result.error(
                check_id,
                "FAIL_CSV_REQUIRED_COLUMNS",
                f"risk register lacks {semantic} column (accepted: {', '.join(aliases)})",
                risk_relative,
            )
        else:
            selected[semantic] = selected_name
    if not rows:
        result.error(
            check_id,
            "FAIL_CSV_ROW_COUNT",
            "risk register must contain at least one row",
            risk_relative,
        )
    ids: list[str] = []
    for line_number, row in enumerate(rows, 2):
        if len(row) != len(header):
            result.error(
                check_id,
                "FAIL_CSV_ROW_WIDTH",
                f"risk row {line_number} width differs from header",
                risk_relative,
            )
            continue
        if any(not value.strip() for value in row):
            result.error(
                check_id,
                "FAIL_CSV_BLANK_CELL",
                f"risk row {line_number} contains a blank cell",
                risk_relative,
            )
        if "id" in selected:
            ids.append(row[header.index(selected["id"])])
    if len(ids) != len(set(ids)):
        result.error(
            check_id,
            "FAIL_CSV_DUPLICATE_ID",
            "risk IDs are not unique",
            risk_relative,
        )
    return {"matrices": len(final_tables) + 1}


def check_no_symlinks(
    result: ValidationResult, check_id: str
) -> Mapping[str, Any]:
    symlinks: list[str] = []
    for path in sorted(result.design_root.rglob("*")):
        if path.is_symlink():
            symlinks.append(path.relative_to(result.design_root).as_posix())
    for relative in symlinks:
        result.error(
            check_id,
            "FAIL_SYMLINK",
            "final design tree may not contain symlinks",
            relative,
        )
    return {"symlinks": len(symlinks)}


def collect_artifact_hashes(
    design_root: Path, report_path: Path
) -> dict[str, dict[str, Any]]:
    hashes: dict[str, dict[str, Any]] = {}
    report_resolved = report_path.resolve(strict=False)
    for path in sorted(design_root.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        if path.resolve(strict=False) == report_resolved:
            continue
        relative = path.relative_to(design_root).as_posix()
        if relative.startswith("validation/runs/"):
            continue
        hashes[relative] = {"sha256": sha256_file(path), "size": path.stat().st_size}
    return hashes


def write_report(path: Path, document: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = json.dumps(
        document, ensure_ascii=False, indent=2, sort_keys=True
    ) + "\n"
    path.write_text(encoded, encoding="utf-8")


def validate(mode: str, root: Path, report_path: Path) -> tuple[int, dict[str, Any]]:
    root = root.expanduser().resolve()
    design_root = root / "docs/design/codex-kernel-v4"
    result = ValidationResult(root, design_root, mode, report_path.expanduser().resolve())

    try:
        details = git_identity(result, "git_identity")
    except RuntimeError as exc:
        result.not_run("git_identity", f"Git identity unavailable: {exc}")
    else:
        result.checks.append({"details": details, "id": "git_identity", "status": PASS})

    inventory_box: dict[str, Any] = {}

    def inventory_callback(check_id: str) -> Mapping[str, Any]:
        inventory, details = load_inventory(result, check_id)
        inventory_box["value"] = inventory
        return details

    inventory_ok = result.run("inventory", inventory_callback)
    inventory = inventory_box.get("value")
    if not inventory_ok or not isinstance(inventory, dict):
        for check_id in (
            "preflight_artifacts",
            "csv_contracts",
            "source_references",
            "markdown_references",
            "identity_contracts",
            "actor_writer_aliases",
            "phase2_candidate_binding",
            "reachable_legacy_markers",
            "control_budgets",
            "file_transfer_naming",
            "r14_operation_preflight",
        ):
            result.not_run(check_id, "inventory unavailable")
        if mode == "final":
            for check_id in (
                "final_artifact_inventory",
                "contract_registry",
                "json_schema_structure",
                "sqlite_fresh_load",
                "sqlite_negative_vectors",
                "final_matrices",
                "final_symlinks",
                "r14_machine_contracts",
            ):
                result.not_run(check_id, "inventory unavailable")
    else:
        result.run(
            "preflight_artifacts",
            lambda check_id: check_required_files(
                result, check_id, inventory["preflight_required_files"]
            ),
        )
        result.run(
            "csv_contracts",
            lambda check_id: check_csv_tables(
                result, check_id, inventory["csv_tables"]
            ),
        )
        result.run(
            "source_references",
            lambda check_id: check_source_references(
                result, check_id, inventory["source_reference_columns"]
            ),
        )
        result.run("markdown_references", lambda check_id: check_markdown_references(result, check_id))
        result.run("identity_contracts", lambda check_id: check_identity_contracts(result, check_id))
        result.run("actor_writer_aliases", lambda check_id: check_aliases(result, check_id))
        result.run(
            "phase2_candidate_binding",
            lambda check_id: check_phase2_candidate_binding(
                result, check_id, inventory["phase2_files"]
            ),
        )
        result.run(
            "reachable_legacy_markers",
            lambda check_id: check_legacy_markers(result, check_id),
        )
        result.run(
            "control_budgets",
            lambda check_id: check_budgets(
                result, check_id, inventory["control_budgets_bytes"]
            ),
        )
        result.run("file_transfer_naming", lambda check_id: check_ft_naming(result, check_id))
        result.run(
            "r14_operation_preflight",
            lambda check_id: check_r14_operation_preflight(result, check_id),
        )

        if mode == "final":
            final_config = inventory["final"]
            final_ok = result.run(
                "final_artifact_inventory",
                lambda check_id: check_final_inventory(result, check_id, final_config),
            )
            if final_ok:
                result.run(
                    "contract_registry",
                    lambda check_id: check_contract_registry(
                        result, check_id, final_config
                    ),
                )
                result.run(
                    "json_schema_structure",
                    lambda check_id: check_json_schemas(result, check_id),
                )
                result.run(
                    "sqlite_fresh_load",
                    lambda check_id: check_sqlite_ddl(result, check_id),
                )
                result.run(
                    "sqlite_negative_vectors",
                    lambda check_id: check_sql_negative_vectors(
                        result, check_id, final_config
                    ),
                )
                result.run(
                    "final_matrices",
                    lambda check_id: check_final_matrices(
                        result, check_id, inventory["csv_tables"]
                    ),
                )
                result.run(
                    "final_symlinks", lambda check_id: check_no_symlinks(result, check_id)
                )
                result.run(
                    "r14_machine_contracts",
                    lambda check_id: check_r14_machine_contracts(result, check_id),
                )
            else:
                reason = "required final artifacts are missing or invalid"
                for check_id in (
                    "contract_registry",
                    "json_schema_structure",
                    "sqlite_fresh_load",
                    "sqlite_negative_vectors",
                    "final_matrices",
                    "final_symlinks",
                    "r14_machine_contracts",
                ):
                    result.not_run(check_id, reason)
        else:
            result.not_run(
                "r14_machine_contracts",
                "final-only machine registry is not present/applicable in preflight mode",
            )

    artifact_hashes = (
        collect_artifact_hashes(design_root, result.report_path)
        if design_root.is_dir()
        else {}
    )
    document = result.document(artifact_hashes)
    return (0 if document["overall_status"] == PASS else 1), document


def run_self_test() -> int:
    cases: list[dict[str, Any]] = []

    def record(case_id: str, expected: str, observed: Iterable[str]) -> None:
        codes = sorted(set(observed))
        cases.append(
            {
                "expected_error": expected,
                "id": case_id,
                "observed_errors": codes,
                "status": PASS if expected in codes else FAIL,
            }
        )

    with tempfile.TemporaryDirectory(prefix="codex-kernel-v4-validator-") as raw:
        temp = Path(raw)
        base_config = {
            "id_column": "id",
            "row_count": 2,
            "min_columns": 2,
            "required_columns": ["id", "value"],
            "id_sequence": [
                {"prefix": "T-", "start": 1, "end": 2, "width": 3}
            ],
        }

        duplicate = temp / "duplicate.csv"
        duplicate.write_text("id,value\nT-001,one\nT-001,two\n", encoding="utf-8")
        record(
            "duplicate_id",
            "FAIL_CSV_DUPLICATE_ID",
            (item["code"] for item in validate_csv_table(duplicate, base_config)),
        )

        blank = temp / "blank.csv"
        blank.write_text("id,value\nT-001,one\nT-002,\n", encoding="utf-8")
        record(
            "blank_cell",
            "FAIL_CSV_BLANK_CELL",
            (item["code"] for item in validate_csv_table(blank, base_config)),
        )

        record(
            "bad_source_partition",
            "FAIL_SOURCE_PARTITION",
            (
                item["code"]
                for item in identity_errors(
                    "SourcePartition=(bridgeInstanceId,codexSourceId)"
                )
            ),
        )

        record(
            "oversize_control_budget",
            "FAIL_CONTROL_BUDGET_OVERSIZE",
            (
                item["code"]
                for item in budget_errors("control envelope <= 65,537 bytes")
            ),
        )

        missing_config = {
            "required_files": ["FULL_DESIGN.md"],
            "required_globs": [],
        }
        missing = final_missing_artifacts(temp, missing_config)
        record(
            "missing_final_artifact",
            MISSING,
            [MISSING] if "FULL_DESIGN.md" in missing else [],
        )

    document = {
        "cases": cases,
        "self_test": PASS if all(case["status"] == PASS for case in cases) else FAIL,
    }
    sys.stdout.write(json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    return 0 if document["self_test"] == PASS else 1


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("preflight", "final"))
    parser.add_argument("--root", type=Path)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if args.self_test:
        if args.mode is not None or args.root is not None or args.report is not None:
            parser.error("--self-test cannot be combined with --mode/--root/--report")
    elif args.mode is None or args.root is None or args.report is None:
        parser.error("--mode, --root, and --report are required unless --self-test is used")
    return args


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if args.self_test:
        return run_self_test()
    assert args.mode is not None and args.root is not None and args.report is not None
    try:
        exit_code, document = validate(args.mode, args.root, args.report)
        write_report(args.report.expanduser().resolve(), document)
    except (OSError, UnicodeError, ValueError) as exc:
        sys.stderr.write(f"validator configuration/report error: {exc}\n")
        return 2
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
