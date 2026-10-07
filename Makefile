NVIM ?= nvim
PYTHON ?= python3
STYLUA ?= stylua

.PHONY: test test-core test-probes test-telescope lint format

test: test-core test-probes

test-core:
	$(NVIM) --headless --clean -l tests/core/run.lua

test-probes:
	$(PYTHON) -B tests/probes/discovery.py
	$(PYTHON) -B tests/probes/workspaces.py
	$(NVIM) --headless --clean -l tests/probes/editor.lua

test-telescope:
	JJ_WORKSPACES_REAL_CORE=1 $(NVIM) --headless --clean -l tests/telescope/run.lua

lint:
	$(STYLUA) --check lua tests/core tests/telescope

format:
	$(STYLUA) lua tests/core tests/telescope
