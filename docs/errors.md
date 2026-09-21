---
description: "SFErrorCodes.Code, string and enum lookups, sentinel values, and where server errors surface."
---

# Errors

Signal Fish error codes travel on the wire as strings such as `ROOM_FULL`.
The client maps them to the `SFErrorCodes.Code` enum so comparisons are
typed and switch-friendly.

`addons/signal_fish/protocol/sf_error_codes.gd` is the single source of
truth: 62 upstream codes plus the cloud-only `DATABASE_ERROR` alias.

## Sentinels

- An absent or optional error code decodes to `SFErrorCodes.Code.NONE`.
- An unknown non-empty server code string decodes to
  `SFErrorCodes.Code.UNKNOWN`. This keeps the client forward-compatible
  with newer servers.

## String and enum lookups

```gdscript
SFErrorCodes.from_string("ROOM_FULL")     # -> SFErrorCodes.Code.ROOM_FULL
SFErrorCodes.from_string("")              # -> SFErrorCodes.Code.NONE
SFErrorCodes.from_string("SOME_NEW_CODE") # -> SFErrorCodes.Code.UNKNOWN
SFErrorCodes.to_wire_string(code)         # -> "ROOM_FULL"; NONE -> ""
SFErrorCodes.is_known("ROOM_FULL")        # -> true
SFErrorCodes.category(code)               # -> "room", "none", "unknown", ...
```

Enum integers are internal only. The wire always uses strings.

## Where errors surface

| Signal | Meaning |
| --- | --- |
| `authentication_error(error, error_code)` | The server rejected authentication. |
| `room_join_failed(reason, error_code)` | A room join was refused. |
| `authority_response(granted, reason, error_code)` | An authority request was refused (`granted` is `false`). |
| `reconnection_failed(reason, error_code)` | A reconnect was refused. |
| `spectator_join_failed(reason, error_code)` | A spectator join was refused. |
| `server_error(message, error_code)` | Generic server-reported error. |
| `protocol_error(error)` | Local, non-fatal problem (decode failure, backpressure, pre-auth send). |

`protocol_error` is local, so it carries no server error code.

## Codes by category

The upstream codes group into the upstream documentation's categories.
Counts include the `DATABASE_ERROR` alias in the server group.

| Category | Codes | Examples |
| --- | --- | --- |
| Authentication | 17 | `UNAUTHORIZED`, `MISSING_APP_ID`, `CONNECT_TOKEN_INVALID` |
| Validation | 7 | `INVALID_INPUT`, `MESSAGE_TOO_LARGE`, `INVALID_ROOM_CODE` |
| Room | 16 | `ROOM_NOT_FOUND`, `ROOM_FULL`, `KICKED` |
| Authority | 3 | `AUTHORITY_DENIED`, `AUTHORITY_CONFLICT` |
| Rate limit | 2 | `RATE_LIMIT_EXCEEDED`, `TOO_MANY_CONNECTIONS` |
| Reconnection | 4 | `RECONNECTION_FAILED`, `RECONNECTION_EXPIRED` |
| Spectator | 4 | `TOO_MANY_SPECTATORS`, `SPECTATOR_JOIN_FAILED` |
| Signaling | 5 | `SIGNAL_TARGET_NOT_FOUND`, `SIGNAL_TOO_LARGE` |
| Server | 5 | `INTERNAL_ERROR`, `STORAGE_ERROR`, `DATABASE_ERROR` |

Read `addons/signal_fish/protocol/sf_error_codes.gd` for the complete list
and the per-code category map.
