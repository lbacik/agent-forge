#!/usr/bin/env python3
"""Read one field out of a contract producer envelope for operate.sh.

Usage: envelope.py <envelope-file> <query>

Queries: ok, code, retryable, request_id, ack, kind, replayed, caps,
backend, repository, mode, contract_major, detail. Prints the value (or an
empty line when the envelope is valid but the field is absent) and exits 0.
Exits 1 when the file is not a valid envelope (not JSON, or neither/both of
ok:true with a result document and ok:false with an error document), so the
caller reports malformed stdout instead of parsing it as success.

 Reads (identity, status) and mutations (stop, resume, ...) share this shape:
 ok:true carries result.command (mutations, command lookup) or result with
 identity fields; ok:false carries error.code, error.retryable and
 error.request_id. Capability lists come from result.capabilities (identity).
"""

import json
import sys


def main():
    if len(sys.argv) != 3:
        sys.stderr.write("usage: envelope.py <envelope-file> <query>\n")
        return 2
    path, query = sys.argv[1], sys.argv[2]
    try:
        with open(path) as handle:
            envelope = json.load(handle)
    except (OSError, ValueError):
        return 1
    if not isinstance(envelope, dict):
        return 1
    ok = envelope.get("ok")
    if ok is True:
        result = envelope.get("result")
        if not isinstance(result, dict):
            return 1
        error = None
    elif ok is False:
        error = envelope.get("error")
        if not isinstance(error, dict):
            return 1
        result = None
    else:
        return 1

    command = None
    if isinstance(result, dict):
        maybe = result.get("command")
        if isinstance(maybe, dict):
            command = maybe

    if query == "ok":
        print("true" if ok is True else "false")
    elif query == "code":
        print(error.get("code", "") if error is not None else "")
    elif query == "retryable":
        if error is not None and error.get("retryable") is True:
            print("true")
        else:
            print("false")
    elif query == "request_id":
        if command is not None and command.get("request_id"):
            print(command.get("request_id"))
        elif error is not None and error.get("request_id"):
            print(error.get("request_id"))
        else:
            print("")
    elif query == "ack":
        print(command.get("acknowledgement", "") if command is not None else "")
    elif query == "kind":
        print(command.get("kind", "") if command is not None else "")
    elif query == "replayed":
        if isinstance(result, dict) and result.get("replayed") is True:
            print("true")
        else:
            print("false")
    elif query == "caps":
        caps = result.get("capabilities") if isinstance(result, dict) else None
        if isinstance(caps, list) and all(isinstance(c, str) for c in caps):
            print(",".join(caps))
        else:
            print("")
    elif query == "backend":
        print(result.get("backend", "") if isinstance(result, dict) else "")
    elif query == "repository":
        if command is not None and command.get("repository"):
            print(command.get("repository"))
        elif isinstance(result, dict):
            print(result.get("repository", ""))
        else:
            print("")
    elif query == "mode":
        print(result.get("mode", "") if isinstance(result, dict) else "")
    elif query == "contract_major":
        contract = result.get("contract") if isinstance(result, dict) else None
        print(contract.get("major", "") if isinstance(contract, dict) else "")
    elif query == "stored":
        details = error.get("details") if error is not None else None
        if isinstance(details, dict) and details.get("stored") is True:
            print("true")
        elif isinstance(details, dict) and details.get("stored") is False:
            print("false")
        else:
            print("")
    elif query == "detail":
        if command is not None and command.get("detail"):
            print(command.get("detail"))
        elif error is not None:
            print(error.get("message", ""))
        else:
            print("")
    else:
        sys.stderr.write(f"envelope.py: unknown query {query!r}\n")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
