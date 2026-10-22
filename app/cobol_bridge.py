"""Runs the COBOL programs (PAYMENT, BALINQ) as subprocesses.

One request record goes in on stdin, one response record comes back on
stdout, and the exit status carries the COBOL RETURN-CODE.
"""

import logging
import os
import subprocess
import threading
from dataclasses import dataclass
from pathlib import Path

from .copybook import BALREQ, BALRSP, PAYREQ, PAYRSP, Layout, RecordMappingError

log = logging.getLogger("cobol_bridge")

PROJECT_DIR = Path(__file__).resolve().parent.parent
PAYMENT_BIN = Path(os.environ.get("PAYMENT_BIN", PROJECT_DIR / "bin" / "PAYMENT"))
BALINQ_BIN = Path(os.environ.get("BALINQ_BIN", PROJECT_DIR / "bin" / "BALINQ"))
ACCOUNT_FILE = Path(os.environ.get("DD_ACCTFILE", PROJECT_DIR / "data" / "ACCOUNTS.DAT"))
TIMEOUT_SECONDS = 5
KNOWN_RETURN_CODES = {0, 4, 8, 12}

# PAYMENT reads a balance, checks it and rewrites it. Two runs at once
# could both read the same old balance, so only one program touches the
# account file at a time. BALINQ takes the lock too, so an inquiry never
# reads a record halfway through a payment.
# This lock covers one API process; see GUIDE.md for multi-process.
_account_file_lock = threading.Lock()


class CobolCallError(RuntimeError):
    """The COBOL program could not be run or replied with garbage."""


@dataclass
class CobolResult:
    return_code: int
    fields: dict


def call_payment(request_fields: dict) -> CobolResult:
    return _run_program(PAYMENT_BIN, PAYREQ, PAYRSP, request_fields)


def call_balance_inquiry(request_fields: dict) -> CobolResult:
    return _run_program(BALINQ_BIN, BALREQ, BALRSP, request_fields)


def _run_program(program: Path, request: Layout, response: Layout, request_fields: dict) -> CobolResult:
    name = program.name
    record = request.encode(request_fields)  # may raise RecordMappingError

    # Map the logical file name ACCTFILE to a real path, like a JCL DD.
    env = {**os.environ, "DD_ACCTFILE": str(ACCOUNT_FILE)}

    with _account_file_lock:
        try:
            proc = subprocess.run(
                [str(program)],
                input=record + "\n",
                capture_output=True,
                text=True,
                encoding="ascii",
                timeout=TIMEOUT_SECONDS,
                env=env,
            )
        except FileNotFoundError:
            raise CobolCallError(f"{program} not found; run 'make build'")
        except subprocess.TimeoutExpired:
            raise CobolCallError(f"{name} did not finish in {TIMEOUT_SECONDS}s")
        except UnicodeDecodeError:
            raise CobolCallError(f"{name} wrote non-ASCII output")

    for line in proc.stderr.splitlines():
        log.info("%s stderr: %s", name, line)

    if proc.returncode not in KNOWN_RETURN_CODES:
        raise CobolCallError(f"{name} ended with unexpected exit status {proc.returncode}")

    # Strip only the newline: trailing spaces are part of the record.
    out = proc.stdout.rstrip("\n")
    try:
        fields = response.decode(out)
    except RecordMappingError as e:
        raise CobolCallError(f"bad response record from {name}: {e}")

    return CobolResult(proc.returncode, fields)
