"""Tests for dev-specific background sync labels."""

from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from devctl.core.background_sync import _devctl_home_env, _launchd_label, install_background_sync


def test_launchd_label_dev_home(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    dev_home = tmp_path / ".devctl-dev"
    monkeypatch.setenv("DEVCTL_HOME", str(dev_home))
    assert _launchd_label() == "com.devctl-dev.config-sync"


def test_devctl_home_env_set_for_dev_install(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    dev_home = tmp_path / ".devctl-dev"
    monkeypatch.setenv("DEVCTL_HOME", str(dev_home))
    monkeypatch.setattr(Path, "home", classmethod(lambda cls: tmp_path))
    assert _devctl_home_env() == {"DEVCTL_HOME": str(dev_home.resolve())}


def test_install_background_sync_dev_plist_includes_devctl_home(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    dev_home = tmp_path / ".devctl-dev"
    monkeypatch.setenv("DEVCTL_HOME", str(dev_home))
    monkeypatch.setattr(Path, "home", classmethod(lambda cls: tmp_path))
    logs = dev_home / "logs"
    monkeypatch.setattr(
        "devctl.core.background_sync.get_logs_dir",
        lambda: logs,
    )
    monkeypatch.setattr(
        "devctl.core.background_sync.get_background_sync_log_path",
        lambda: logs / "background-sync.log",
    )
    fake_devctl = str(tmp_path / "devctl-dev")
    Path(fake_devctl).write_text("#!/bin/sh\necho ok\n")

    with (
        patch("devctl.core.background_sync.platform.system", return_value="darwin"),
        patch("devctl.core.background_sync._get_devctl_path", return_value=fake_devctl),
        patch("devctl.core.background_sync.subprocess.run") as run,
    ):
        run.return_value = MagicMock(returncode=0)
        ok, msg = install_background_sync()

    assert ok is True
    plist = tmp_path / "Library" / "LaunchAgents" / "com.devctl-dev.config-sync.plist"
    assert plist.exists()
    plist_text = plist.read_text()
    assert "DEVCTL_HOME" in plist_text
    assert str(dev_home) in plist_text
    assert fake_devctl in plist_text
