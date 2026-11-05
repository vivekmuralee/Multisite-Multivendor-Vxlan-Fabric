SHELL       := /bin/bash
PYTHON      ?= python3
VENV        ?= .venv
REQS        ?= requirements.txt
BASE        ?= main
REMOTE      ?= origin
VENDOR      ?= cumulus
PLAYBOOK    ?= site.yml

BIN         := $(VENV)/bin
CURRENT     := $(shell git rev-parse --abbrev-ref HEAD 2>/dev/null)

.DEFAULT_GOAL := help
.PHONY: help venv install upgrade clean-venv run check syntax status branch commit push pr

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  Examples:"
	@echo "    make venv"
	@echo "    make run VENDOR=cumulus PLAYBOOK=site.yml"
	@echo "    make branch BRANCH=feature/arista-prod-vrf"
	@echo "    make commit MSG=\"Fix anycast MAC\""
	@echo "    make push"
	@echo "    make pr"

# ---------------------------------------------------------------- venv

$(BIN)/activate:
	$(PYTHON) -m venv $(VENV)
	$(BIN)/pip install --upgrade pip

venv: $(BIN)/activate install ## Create the venv and install requirements
	@echo "Activate with: source $(BIN)/activate"

install: $(BIN)/activate ## Install requirements into the venv
	$(BIN)/pip install -r $(REQS)

upgrade: $(BIN)/activate ## Upgrade pip and reinstall requirements
	$(BIN)/pip install --upgrade pip
	$(BIN)/pip install --upgrade -r $(REQS)

clean-venv: ## Delete the venv
	rm -rf $(VENV)

# ---------------------------------------------------------------- ansible

run: $(BIN)/activate ## Run a playbook (VENDOR=cumulus PLAYBOOK=site.yml ARGS=...)
	cd $(VENDOR) && $(CURDIR)/$(BIN)/ansible-playbook $(PLAYBOOK) $(ARGS)

check: $(BIN)/activate ## Dry-run a playbook with --check --diff
	cd $(VENDOR) && $(CURDIR)/$(BIN)/ansible-playbook $(PLAYBOOK) --check --diff $(ARGS)

syntax: $(BIN)/activate ## Syntax-check a playbook
	cd $(VENDOR) && $(CURDIR)/$(BIN)/ansible-playbook $(PLAYBOOK) --syntax-check

# ---------------------------------------------------------------- git

status: ## Show branch and working tree status
	@git status -sb

branch: ## Create a new branch from an updated BASE (BRANCH=name)
	@test -n "$(BRANCH)" || { echo "Usage: make branch BRANCH=feature/name"; exit 1; }
	git fetch $(REMOTE)
	git switch $(BASE)
	git pull --ff-only $(REMOTE) $(BASE)
	git switch -c $(BRANCH)

commit: ## Stage all changes and commit (MSG="message")
	@test -n "$(MSG)" || { echo "Usage: make commit MSG=\"message\""; exit 1; }
	git add -A
	git commit -m "$(MSG)"

push: ## Push the current branch and set upstream (refuses BASE)
	@test "$(CURRENT)" != "$(BASE)" || { echo "Refusing to push $(BASE) directly; run 'make branch BRANCH=...' first"; exit 1; }
	git push -u $(REMOTE) $(CURRENT)

pr: push ## Push the current branch and open a GitHub PR against BASE
	gh pr create --base $(BASE) --head $(CURRENT) --fill
