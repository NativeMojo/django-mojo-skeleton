import ast
import re
import tempfile
from pathlib import Path
from unittest import mock

from testit import helpers as th


@th.unit_test("check_var creates a complete generated django.conf")
def test_check_var_accepts_initialization(opts):
    import paths as scaffold_paths
    from mojo.helpers.settings.parser import DjangoConfigLoader

    with tempfile.TemporaryDirectory() as temp_dir:
        var_root = Path(temp_dir) / "var"
        with mock.patch.object(scaffold_paths, "VAR_ROOT", var_root), \
                mock.patch("builtins.input", side_effect=["y", "test"]):
            scaffold_paths.check_var()

        assert var_root.is_dir(), "Accepted initialization should create VAR_ROOT"
        assert (var_root / "profile").read_text() == "test", \
            "Accepted initialization should save the selected test profile"
        assert (var_root / "logs").is_dir(), \
            "Accepted initialization should create the logs directory"
        assert (var_root / "keys").is_dir(), \
            "Accepted initialization should create the keys directory"

        config_path = var_root / "django.conf"
        config_text = config_path.read_text()
        config_lines = config_text.splitlines()
        assert config_text.endswith("\n"), \
            "Generated django.conf should end with one parseable trailing newline"
        assert len(config_lines) == 5, \
            f"Generated django.conf should contain exactly five assignments, got {config_lines!r}"
        assert re.fullmatch(r"SECRET_KEY = '[A-Za-z0-9]{50}'", config_lines[0]), \
            f"First assignment should be a 50-character alphanumeric SECRET_KEY, got {config_lines[0]!r}"
        assert config_lines[1:4] == [
            "ALLOW_ADMIN_SITE = False",
            "ADMIN_SITE_PREFIX = 'admin'",
            "OPENAPI_DOCS_SHOW = False",
        ], f"Middle assignments should retain their exact order and values, got {config_lines[1:4]!r}"
        assert re.fullmatch(r"OPENAPI_DOCS_KEY = '[A-Z]{4}-[a-z]{4}'", config_lines[4]), \
            f"Final assignment should use the generated docs-key pattern, got {config_lines[4]!r}"

        loaded = {}
        DjangoConfigLoader(config_path=config_path).load_config(loaded)
        assert list(loaded) == [
            "SECRET_KEY",
            "ALLOW_ADMIN_SITE",
            "ADMIN_SITE_PREFIX",
            "OPENAPI_DOCS_SHOW",
            "OPENAPI_DOCS_KEY",
        ], f"Config loader should round-trip exactly the five generated settings, got {loaded!r}"
        assert type(loaded["SECRET_KEY"]) is str, \
            f"SECRET_KEY should load as str, got {type(loaded['SECRET_KEY']).__name__}"
        assert len(loaded["SECRET_KEY"]) == 50 and loaded["SECRET_KEY"].isalnum(), \
            f"SECRET_KEY should load as 50 alphanumeric characters, got {loaded['SECRET_KEY']!r}"
        assert type(loaded["ALLOW_ADMIN_SITE"]) is bool and loaded["ALLOW_ADMIN_SITE"] is False, \
            f"ALLOW_ADMIN_SITE should load as boolean False, got {loaded['ALLOW_ADMIN_SITE']!r}"
        assert type(loaded["ADMIN_SITE_PREFIX"]) is str and loaded["ADMIN_SITE_PREFIX"] == "admin", \
            f"ADMIN_SITE_PREFIX should load as string 'admin', got {loaded['ADMIN_SITE_PREFIX']!r}"
        assert type(loaded["OPENAPI_DOCS_SHOW"]) is bool and loaded["OPENAPI_DOCS_SHOW"] is False, \
            f"OPENAPI_DOCS_SHOW should load as boolean False, got {loaded['OPENAPI_DOCS_SHOW']!r}"
        assert type(loaded["OPENAPI_DOCS_KEY"]) is str, \
            f"OPENAPI_DOCS_KEY should load as str, got {type(loaded['OPENAPI_DOCS_KEY']).__name__}"
        assert re.fullmatch(r"[A-Z]{4}-[a-z]{4}", loaded["OPENAPI_DOCS_KEY"]), \
            f"OPENAPI_DOCS_KEY should load with the expected generated pattern, got {loaded['OPENAPI_DOCS_KEY']!r}"


@th.unit_test("check_var declines without creating VAR_ROOT")
def test_check_var_declines_initialization(opts):
    import paths as scaffold_paths

    with tempfile.TemporaryDirectory() as temp_dir:
        var_root = Path(temp_dir) / "var"
        with mock.patch.object(scaffold_paths, "VAR_ROOT", var_root), \
                mock.patch("builtins.input", return_value="n"):
            scaffold_paths.check_var()

        assert not var_root.exists(), \
            "Declined initialization should leave VAR_ROOT absent"


@th.unit_test("settings profiles do not define fallback SECRET_KEY values")
def test_settings_modules_have_no_secret_key_assignment(opts):
    import paths as scaffold_paths

    settings_root = scaffold_paths.CONFIG_ROOT / "settings"
    relative_paths = (
        Path("defaults/__init__.py"),
        Path("local/__init__.py"),
        Path("test/__init__.py"),
    )

    for relative_path in relative_paths:
        settings_path = settings_root / relative_path
        module = ast.parse(settings_path.read_text(), filename=str(settings_path))
        assignments = []
        for node in module.body:
            if isinstance(node, ast.Assign):
                assignments.extend(
                    target.id for target in node.targets
                    if isinstance(target, ast.Name) and target.id == "SECRET_KEY"
                )
            elif isinstance(node, ast.AnnAssign) and \
                    isinstance(node.target, ast.Name) and node.target.id == "SECRET_KEY":
                assignments.append(node.target.id)

        assert not assignments, \
            f"{relative_path} should not define a top-level SECRET_KEY fallback"
