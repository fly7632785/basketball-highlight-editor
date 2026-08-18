.PHONY: setup-python python-test check-open-source flutter-desktop-analyze flutter-desktop-test

PYTHON ?= python3
VENV ?= .venv
VENV_PYTHON := $(VENV)/bin/python

setup-python:
	$(PYTHON) -m venv $(VENV)
	$(VENV_PYTHON) -m pip install -r requirements-dev.txt

python-test:
	$(VENV_PYTHON) -m pytest -q

check-open-source:
	$(PYTHON) scripts/check_open_source.py

flutter-desktop-analyze:
	cd apps/desktop && flutter analyze

flutter-desktop-test:
	cd apps/desktop && flutter test
