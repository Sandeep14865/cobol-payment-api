"""Runs the COBOL PAYMENT program as a subprocess.

One request record goes in on stdin, one response record comes back on
stdout, and the exit status carries the COBOL RETURN-CODE.
"""

import logging
import os
import subprocess
import threading
from dataclasses import dataclass
from pathlib import Path

from .copybook import PAYREQ, PAYRSP, RecordMappingError

log = logging.getLogger("cobol_bridge")

PROJECT_DIR = Path(__file__).resolve().parent.parent
PAYMENT_BIN = Path(os.environ.get("PAYMENT_BIN", PROJECT_DIR / "bin" / "PAYMENT"))
ACCOUNT_FILE = Path(os.environ.get("DD_ACCTFILE", PROJECT_DIR / "data" / "ACCOUNTS.DAT"))
TIMEOUT_SECONDS = 5
KNOWN_RETURN_CODES = {0, 4, 8, 12}

# PAYMENT reads a balance, checks it and rewrites it. Two runs at once
# could both read the same old balance, so only one runs at a time.
# This lock covers one API process; see GUIDE.md for multi-process.
_payment_lock = threading.Lock()


class CobolCallError(RuntimeError):
    """The COBOL program could not be run or replied with garbage."""


@dataclass
class CobolResult:
    return_code: int
    fields: dict


def call_payment(request_fields: dict) -> CobolResult:
    record = PAYREQ.encode(request_fields)  # may raise RecordMappingError

    # Map the logical file name ACCTFILE to a real path, like a JCL DD.
    env = {**os.environ, "DD_ACCTFILE": str(ACCOUNT_FILE)}

    with _payment_lock:
        try:
            proc = subprocess.run(
                [str(PAYMENT_BIN)],
                input=record + "\n",
                capture_output=True,
                text=True,
                encoding="ascii",
                timeout=TIMEOUT_SECONDS,
                env=env,
            )
        except FileNotFoundError:
            raise CobolCallError(f"{PAYMENT_BIN} not found; run 'make build'")
        except subprocess.TimeoutExpired:
            raise CobolCallError(f"PAYMENT did not finish in {TIMEOUT_SECONDS}s")
        except UnicodeDecodeError:
            raise CobolCallError("PAYMENT wrote non-ASCII output")

    for line in proc.stderr.splitlines():
        log.info("PAYMENT stderr: %s", line)

    if proc.returncode not in KNOWN_RETURN_CODES:
        raise CobolCallError(f"PAYMENT ended with unexpected exit status {proc.returncode}")

    # Strip only the newline: trailing spaces are part of the record.
    out = proc.stdout.rstrip("\n")
    try:
        fields = PAYRSP.decode(out)
    except RecordMappingError as e:
        raise CobolCallError(f"bad response record: {e}")

    return CobolResult(proc.returncode, fields)
