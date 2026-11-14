"""Runs every Gherkin scenario under .specify/features (step definitions: e2e/steps).

Scenarios tagged @pending (no automation yet) or @linked (covered by a test that
declares `covers`) are deselected by support/executions.py.
"""
from pytest_bdd import scenarios

from support.executions import FEATURES

scenarios(str(FEATURES))
