# Build the COBOL programs, load demo data, run the API.
# Usage: make build | make seed | make run | make test | make clean

COBC     = cobc
COBFLAGS = -x -Wall -I cobol/copybooks
BIN      = bin

# Logical file names used in the COBOL SELECT ... ASSIGN TO clauses,
# mapped to real paths (the GnuCOBOL equivalent of JCL DD statements).
export DD_ACCTFILE = $(CURDIR)/data/ACCOUNTS.DAT
export DD_SEEDFILE = $(CURDIR)/data/accounts.seed

.PHONY: build seed run test clean

build: $(BIN)/PAYMENT $(BIN)/ACCTLOAD $(BIN)/PAYJSON

$(BIN)/%: cobol/%.cbl cobol/copybooks/*.cpy
	@mkdir -p $(BIN)
	$(COBC) $(COBFLAGS) -o $@ $<

seed: $(BIN)/ACCTLOAD
	$(BIN)/ACCTLOAD

run: build
	.venv/bin/uvicorn app.main:app --reload --port 8000

test:
	./tests/curl_tests.sh

clean:
	rm -rf $(BIN) data/ACCOUNTS.DAT*
