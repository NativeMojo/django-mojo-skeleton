import json
from pathlib import Path

from testit import helpers as th


@th.unit_test("apps.json installs dnsman alongside edge")
def test_apps_json_edge_requires_dnsman(opts):
    apps_json_path = Path(__file__).resolve().parents[2] / "apps.json"
    config = json.loads(apps_json_path.read_text())

    installed = config.get("installed")
    assert isinstance(installed, list) and installed, \
        "apps.json should declare a non-empty installed list"
    assert all(isinstance(app, str) for app in installed), \
        "apps.json installed entries should all be strings"

    if "mojo.apps.edge" in installed:
        assert "mojo.apps.dnsman" in installed, \
            "mojo.apps.edge requires mojo.apps.dnsman in INSTALLED_APPS " \
            "(edge models hold FKs to dnsman.Domain and dnsman.Certificate)"


@th.unit_test("apps.json installs aws alongside its account and incident dependencies")
def test_apps_json_aws_requires_account_and_incident(opts):
    apps_json_path = Path(__file__).resolve().parents[2] / "apps.json"
    config = json.loads(apps_json_path.read_text())
    installed = config.get("installed")

    assert "mojo.apps.aws" in installed, \
        "apps.json should install mojo.apps.aws so the AWS System Setup " \
        "sections and admin readiness rows register on a fresh clone"

    if "mojo.apps.aws" in installed:
        assert "mojo.apps.account" in installed, \
            "mojo.apps.aws migrations depend on account (e.g. 0014_notificationdelivery_data_payload_and_more)"
        assert "mojo.apps.incident" in installed, \
            "mojo.apps.aws migrations depend on incident (e.g. 0034_incidenthistory_metadata_maestroitemlink)"
