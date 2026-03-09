.PHONY: help all setup deps build fmt fmt-check lint test coverage ci dialyzer

MIX ?= mix

help:
	@echo "Targets: setup, deps, build, fmt, fmt-check, lint, test, coverage, dialyzer, ci, all"

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

build:
	$(MIX) compile --warnings-as-errors

fmt:
	$(MIX) format

fmt-check:
	$(MIX) format --check-formatted

lint:
	$(MIX) lint

test:
	$(MIX) test

coverage:
	$(MIX) test --cover

dialyzer:
	$(MIX) deps.get
	$(MIX) dialyzer --format short

ci:
	$(MAKE) setup
	$(MAKE) build
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) coverage
	$(MAKE) dialyzer

all: ci
