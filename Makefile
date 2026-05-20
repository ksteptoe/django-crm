# --- Makefile (django-crm; DigitalOcean droplet, Ubuntu/bash) ----------------
# Adapted for the prod droplet, NOT a laptop dev checkout. Key facts it assumes:
#   - The venv already exists at /opt/django-crm/venv and is owned by `django`.
#     This Makefile DRIVES that venv; it never builds a copy inside the repo.
#   - Identity split: you run `make` as `kevin` (you own the code tree).
#     Anything that writes django-owned data (db/static, createsuperuser, etc.)
#     is wrapped in `sudo -u django` so it doesn't hit "readonly database".
#   - Targets that only read (check, dumpdata, test) run as you.
#   - gunicorn already listens on 127.0.0.1:8000 (the live service), so the dev
#     `serve` target defaults to :8001 to avoid the clash.
#   - Tag-based releases push to Kevin's fork over SSH. See the WARNING by them.
# -----------------------------------------------------------------------------

.SILENT:
.ONESHELL:
SHELL := $(shell which bash)
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# ---- Python / venv ----------------------------------------------------------
# The real, deploy-managed venv (owned by django). We run it; we don't rebuild it.
VENV := /opt/django-crm/venv
PY   := $(VENV)/bin/python

# LANDMINE: massmail/tasks AppConfig.ready() grab tendo singleton lock files on
# EVERY manage.py run (flavors Massmail, MonthlySnapshotSaving, Reminder),
# named by entry-point and placed in TMPDIR (default /tmp). The deploy created
# the /tmp copies as `django`, so a kevin-run manage.py can't reopen them and
# dies with PermissionError. Give your (kevin) runs a private lock dir to dodge
# it; django-run commands keep using /tmp (it owns those, no clash with gunicorn
# whose locks are keyed '...-gunicorn-...').
LOCKDIR := $(HOME)/.cache/crm-locks

# Two ways to invoke manage.py:
#   MANAGE     -> as you (kevin), private locks. Read-only / code-only commands.
#   MANAGE_DJ  -> as the service account, /tmp locks. Writes db/static/media.
MANAGE    := env TMPDIR=$(LOCKDIR) $(PY) manage.py
MANAGE_DJ := sudo -u django $(PY) manage.py

SERVICE := django-crm

# Dev runserver host:port. 8000 is gunicorn, so default to 8001.
HOST ?= 127.0.0.1
PORT ?= 8001

# Default release kind for `make release` (patch|minor|major)
KIND ?= patch

.PHONY: help check-venv bootstrap dev-tools clean \
        lint format check \
        test test-app \
        serve shell migrate makemigrations superuser collectstatic loaddata dumpdata \
        restart status logs \
        fetch-tags version changelog changelog-md release-show check-clean \
        release release-patch release-minor release-major

help:
	@echo "Run as 'kevin'. Targets marked [django] elevate via 'sudo -u django'."
	@echo ""
	@echo "  make bootstrap           - (re)install requirements.txt + ruff into the prod venv [django]"
	@echo "  make dev-tools           - install just ruff into the prod venv [django]"
	@echo "  make lint                - run Ruff checks"
	@echo "  make format              - auto-fix via Ruff (check --fix + format)"
	@echo "  make check               - django system check"
	@echo "  make test                - manage.py test --keepdb (in-memory sqlite)"
	@echo "  make test-app APP=crm    - run tests for one app"
	@echo "  make makemigrations      - manage.py makemigrations (writes to code tree; warns first)"
	@echo "  make migrate             - manage.py migrate [django]"
	@echo "  make superuser           - manage.py createsuperuser [django]"
	@echo "  make collectstatic       - manage.py collectstatic --noinput [django]"
	@echo "  make loaddata FIXTURE=x  - manage.py loaddata <FIXTURE> [django]"
	@echo "  make dumpdata APP=x      - manage.py dumpdata <APP> > <APP>.json"
	@echo "  make shell               - manage.py shell [django]"
	@echo "  make serve               - manage.py runserver $(HOST):$(PORT) [django] (dev only; gunicorn owns :8000)"
	@echo "  make restart             - systemctl restart $(SERVICE) (load code changes) [sudo]"
	@echo "  make status              - systemctl status $(SERVICE)"
	@echo "  make logs N=100          - tail journalctl for $(SERVICE) [sudo]"
	@echo "  make version             - print latest git tag"
	@echo "  make changelog           - show changes since last tag"
	@echo "  make changelog-md        - write docs/CHANGELOG.md from git history"
	@echo "  make release-show        - show venv python, latest tag"
	@echo "  make release             - test, show changelog, tag+push (KIND=patch|minor|major)  *see WARNING*"
	@echo "  make clean               - remove caches"

# ---- Venv guard / dependency management ------------------------------------
# The venv is created and owned by `django` at deploy time. We only verify it.
check-venv:
	@if [ ! -x "$(PY)" ]; then \
	  echo "Prod venv not found at $(VENV) (expected $(PY))."; \
	  echo "It is created/owned by the 'django' user at deploy time, not by make."; \
	  exit 1; \
	fi
	@mkdir -p "$(LOCKDIR)"

bootstrap: check-venv
	@echo "Refreshing deps into $(VENV) as django..."
	sudo -u django "$(PY)" -m pip install -U pip setuptools wheel
	sudo -u django "$(PY)" -m pip install -r requirements.txt
	sudo -u django "$(PY)" -m pip install ruff
	@echo "Done. Restart the service if code/deps changed: make restart"

dev-tools: check-venv
	sudo -u django "$(PY)" -m pip install ruff

# ---- Linting / Formatting (read-only; run as you) --------------------------
lint: check-venv
	"$(PY)" -m ruff check .
	"$(PY)" -m ruff format --check .

format: check-venv
	"$(PY)" -m ruff check --fix .
	"$(PY)" -m ruff format .

# ---- Django: read-only / code-only (run as you, kevin) ---------------------
check: check-venv
	$(MANAGE) check

test: check-venv
	$(MANAGE) test --keepdb

test-app: check-venv
	@if [ -z "$(APP)" ]; then echo "Usage: make test-app APP=<app_name>"; exit 1; fi
	$(MANAGE) test --keepdb $(APP)

# makemigrations writes migration files INTO the code tree (you own it) and
# does not touch the DB -> runs as you, not django.
makemigrations: check-venv
	@echo "⚠  django-crm ships its own migrations. Only run this if you've"
	@echo "   intentionally modified a model. Ctrl-C now to abort."
	@sleep 2
	$(MANAGE) makemigrations

dumpdata: check-venv
	@if [ -z "$(APP)" ]; then echo "Usage: make dumpdata APP=<app_name> [OUT=path.json]"; exit 1; fi
	$(MANAGE) dumpdata $(APP) --indent 2 > $(if $(OUT),$(OUT),$(APP).json)

# ---- Django: writes django-owned data (elevate to the service account) -----
migrate: check-venv
	$(MANAGE_DJ) migrate

superuser: check-venv
	$(MANAGE_DJ) createsuperuser

collectstatic: check-venv
	$(MANAGE_DJ) collectstatic --noinput

loaddata: check-venv
	@if [ -z "$(FIXTURE)" ]; then echo "Usage: make loaddata FIXTURE=<name>"; exit 1; fi
	$(MANAGE_DJ) loaddata $(FIXTURE)

shell: check-venv
	$(MANAGE_DJ) shell

# Dev server only. Prod traffic is Caddy -> gunicorn:8000. Runs as django so
# session/login writes work; defaults to :8001 to avoid the gunicorn clash.
serve: check-venv
	$(MANAGE_DJ) runserver $(HOST):$(PORT)

# ---- systemd service control -----------------------------------------------
restart:
	sudo systemctl restart $(SERVICE)
	@echo "Restarted $(SERVICE)."

status:
	systemctl status $(SERVICE) --no-pager || true

logs:
	sudo journalctl -u $(SERVICE) -n $(if $(N),$(N),100) --no-pager

# ---- Version & Release helpers (git tag based) -----------------------------
# WARNING: this fork tracks upstream DjangoCRM/django-crm. `fetch-tags` pulls
# upstream's tags (v2.4.0, ...), so release-* will compute the NEXT version
# from upstream's and tag the CURRENT HEAD (likely upstream code) under your
# fork. Only use release-* if you are deliberately starting your own version
# line; otherwise it just pollutes the tag space. Tags push over SSH to origin.
fetch-tags:
	@git fetch --tags --force --prune 2>/dev/null || true

LAST_TAG := $(strip $(shell git tag --list "v[0-9]*.[0-9]*.[0-9]*" --sort=-version:refname | head -n 1))
ifeq ($(LAST_TAG),)
LAST_TAG := v0.0.0
endif

MAJOR := $(shell echo "$(LAST_TAG)" | sed 's/^v//' | cut -d. -f1)
MINOR := $(shell echo "$(LAST_TAG)" | sed 's/^v//' | cut -d. -f2)
PATCH := $(shell echo "$(LAST_TAG)" | sed 's/^v//' | cut -d. -f3)

ifeq ($(strip $(MAJOR)),)
MAJOR := 0
endif
ifeq ($(strip $(MINOR)),)
MINOR := 0
endif
ifeq ($(strip $(PATCH)),)
PATCH := 0
endif

version:
	@echo "$(LAST_TAG)"

define CHANGELOG
$(shell \
  if git rev-parse "$(LAST_TAG)" >/dev/null 2>&1; then \
    git log "$(LAST_TAG)..HEAD" --pretty=format:"- %s (%h)" --no-merges; \
  else \
    git log HEAD --pretty=format:"- %s (%h)" --no-merges; \
  fi \
)
endef

changelog: fetch-tags
	@echo "Changes since $(LAST_TAG):"
	@echo "$(CHANGELOG)"

changelog-md: fetch-tags
	@mkdir -p docs
	@echo "Writing docs/CHANGELOG.md ..."
	@printf "# Changelog\n\n## Since %s\n\n%s\n" "$(LAST_TAG)" "$(CHANGELOG)" > docs/CHANGELOG.md
	@echo "docs/CHANGELOG.md updated"

release-show: fetch-tags
	@echo "venv python:"; "$(PY)" -c "import sys; print(sys.executable)" 2>/dev/null || echo "(venv missing)"
	@echo "Last Git tag: $(LAST_TAG)"
	@echo "Parsed: MAJOR=$(MAJOR) MINOR=$(MINOR) PATCH=$(PATCH)"

check-clean:
	@if ! git diff --quiet || ! git diff --cached --quiet; then \
	  echo "Working directory not clean. Commit or stash changes before releasing."; \
	  git status -s; \
	  exit 1; \
	fi
	@if [ -n "$$(git rev-parse @{u} 2>/dev/null || true)" ] && \
	   [ "$$(git rev-parse @)" != "$$(git rev-parse @{u})" ]; then \
	  echo "Local branch not in sync with upstream (push/pull first)."; \
	  exit 1; \
	fi

release-patch: fetch-tags check-clean
	@NEW="v$(MAJOR).$(MINOR).$$(($(PATCH) + 1))"; \
	echo "Tagging $$NEW (from LAST_TAG=$(LAST_TAG))"; \
	TMP="$$(mktemp -t crm-tagmsg.XXXXXX)"; \
	printf 'release: %s\n\n%s\n' "$$NEW" "$(CHANGELOG)" > "$$TMP"; \
	git tag -a "$$NEW" -F "$$TMP"; \
	rm -f "$$TMP"; \
	git push origin "$$NEW"; \
	echo "Tagged $$NEW"

release-minor: fetch-tags check-clean
	@NEW="v$(MAJOR).$$(($(MINOR) + 1)).0"; \
	echo "Tagging $$NEW (from LAST_TAG=$(LAST_TAG))"; \
	TMP="$$(mktemp -t crm-tagmsg.XXXXXX)"; \
	printf 'release: %s\n\n%s\n' "$$NEW" "$(CHANGELOG)" > "$$TMP"; \
	git tag -a "$$NEW" -F "$$TMP"; \
	rm -f "$$TMP"; \
	git push origin "$$NEW"; \
	echo "Tagged $$NEW"

release-major: fetch-tags check-clean
	@NEW="v$$(($(MAJOR) + 1)).0.0"; \
	echo "Tagging $$NEW (from LAST_TAG=$(LAST_TAG))"; \
	TMP="$$(mktemp -t crm-tagmsg.XXXXXX)"; \
	printf 'release: %s\n\n%s\n' "$$NEW" "$(CHANGELOG)" > "$$TMP"; \
	git tag -a "$$NEW" -F "$$TMP"; \
	rm -f "$$TMP"; \
	git push origin "$$NEW"; \
	echo "Tagged $$NEW"

release: fetch-tags check-venv
	@echo "=== Running tests before release ==="
	$(MAKE) test
	@echo "=== Changelog (from $(LAST_TAG) to HEAD) ==="
	$(MAKE) changelog
	@echo "=== Performing $(KIND) release ==="
	@if [ "$(KIND)" = "patch" ]; then \
	  $(MAKE) release-patch; \
	elif [ "$(KIND)" = "minor" ]; then \
	  $(MAKE) release-minor; \
	elif [ "$(KIND)" = "major" ]; then \
	  $(MAKE) release-major; \
	else \
	  echo "Unknown KIND=$(KIND). Use: patch | minor | major"; \
	  exit 1; \
	fi

# ---- Clean ------------------------------------------------------------------
clean:
	find . -type d -name "__pycache__" -prune -exec rm -rf {} + 2>/dev/null || true
	rm -rf .ruff_cache build dist *.egg-info
	@echo "cleaned."
