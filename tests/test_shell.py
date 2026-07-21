"""Tests for shell path helpers."""

from pathlib import Path

import pytest

from devctl.utils import shell


def test_get_devctl_home_default(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.delenv("DEVCTL_HOME", raising=False)
    monkeypatch.setenv("HOME", str(tmp_path))
    assert shell.get_devctl_home() == tmp_path / ".devctl"


def test_get_devctl_home_override(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    dev_home = tmp_path / ".devctl-dev"
    monkeypatch.setenv("DEVCTL_HOME", str(dev_home))
    assert shell.get_devctl_home() == dev_home


def test_get_state_path_uses_devctl_home(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    dev_home = tmp_path / "custom-devctl"
    monkeypatch.setenv("DEVCTL_HOME", str(dev_home))
    assert shell.get_state_path() == dev_home / "state.json"


def test_get_repos_dir_uses_devctl_home(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    dev_home = tmp_path / "custom-devctl"
    monkeypatch.setenv("DEVCTL_HOME", str(dev_home))
    assert shell.get_repos_dir() == dev_home / "repos"
