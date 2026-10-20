"""Bounded schema discovery shared by local, SDK and MCP clients."""
from __future__ import annotations
import base64
import copy
import hashlib
import json

_MAX = 100
_HASH_CACHE = None


def arguments_schema():
    from _workbench_schema import _object
    return _object({"prefix": {"type": "string", "minLength": 0, "maxLength": 100},
                    "query": {"type": "string", "minLength": 0, "maxLength": 200},
                    "mutating": {"type": "boolean"}, "includeSchemas": {"type": "boolean", "default": False},
                    "limit": {"type": "integer", "minimum": 1, "maximum": _MAX, "default": 25},
                    "cursor": {"type": "string", "minLength": 1, "maxLength": 4096}})


def operations():
    from _workbench_schema import _op
    return [_op("operations.discover", "Find bounded pages of canonical operations and optionally their exact argument schemas.", arguments_schema(), project=False)]


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()).hexdigest()


def page_cursor(offset, identity):
    return base64.urlsafe_b64encode(json.dumps({"offset": offset, "identity": identity}, separators=(",", ":")).encode()).decode().rstrip("=")


def page_offset(cursor, identity, total):
    from _workbench_schema import WorkbenchError
    if cursor is None:
        return 0
    try:
        if not isinstance(cursor, str) or len(cursor) > 4096:
            raise ValueError()
        value = json.loads(base64.b64decode(cursor + "=" * (-len(cursor) % 4), altchars=b"-_", validate=True))
        offset = value["offset"]
        if set(value) != {"offset", "identity"} or value["identity"] != identity or type(offset) is not int or not 0 <= offset <= total:
            raise ValueError()
        return offset
    except (ValueError, KeyError, TypeError, UnicodeError):
        raise WorkbenchError("invalid-discovery-cursor", "The cursor does not match these filters/catalogue. Start a new discovery page.") from None


def discover(arguments, catalogue=None):
    from _workbench_schema import OPERATIONS, validate_value
    global _HASH_CACHE
    validate_value(arguments, arguments_schema(), "arguments")
    if catalogue is None:
        catalogue = OPERATIONS
        if _HASH_CACHE is None: _HASH_CACHE = digest(catalogue)
        catalogue_hash = _HASH_CACHE
    else:
        catalogue_hash = digest(catalogue)
    filters = {"prefix": arguments.get("prefix", ""), "query": arguments.get("query", ""),
               "includeSchemas": arguments.get("includeSchemas", False)}
    if "mutating" in arguments: filters["mutating"] = arguments["mutating"]
    query = filters["query"].casefold()
    selected = sorted((entry for entry in catalogue if entry["name"].startswith(filters["prefix"])
                       and (not query or query in (entry["name"] + " " + entry["description"]).casefold())
                       and ("mutating" not in filters or bool(entry.get("mutating")) == filters["mutating"])), key=lambda entry: entry["name"])
    identity = digest({"catalogueHash": catalogue_hash, "filters": filters})
    start = page_offset(arguments.get("cursor"), identity, len(selected))
    stop = min(start + arguments.get("limit", 25), len(selected))
    return {"operations": [{key: copy.deepcopy(value) for key, value in entry.items()
                            if filters["includeSchemas"] or key not in ("inputSchema", "outputSchema")} for entry in selected[start:stop]],
            "nextCursor": page_cursor(stop, identity) if stop < len(selected) else None,
            "total": len(selected), "catalogueHash": catalogue_hash, "filters": filters,
            "limits": {"pageSize": _MAX},
            "notes": ["Discovery describes declared capabilities, not proof that optional dependencies, files or services are available. Capability-specific inspect/probe operations report readiness."]}
