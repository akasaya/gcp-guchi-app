import pytest
from unittest.mock import patch, MagicMock

@pytest.fixture(scope="session", autouse=True)
def mock_google_auth():
    """
    Mocks google.auth.default for the entire test session to avoid
    DefaultCredentialsError in CI environments. This allows main.py to initialize correctly.
    """
    with patch("google.auth.default", return_value=(MagicMock(), "test-project-id")):
        yield