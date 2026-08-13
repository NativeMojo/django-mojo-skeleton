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
