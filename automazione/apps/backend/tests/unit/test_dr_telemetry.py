from datetime import UTC, datetime, timedelta

import pytest

from helios_bff.domain.telemetry import age_seconds, classify


@pytest.mark.unit
def test_classify_returns_unknown_when_no_measurement_exists() -> None:
    # Arrange / Act
    status = classify(None, 900)

    # Assert: assenza di misura non e' un guasto, e non deve nemmeno passare
    # per "ok" mostrando un obiettivo rispettato che nessuno ha verificato.
    assert status == "unknown"


@pytest.mark.unit
@pytest.mark.parametrize(
    ("value_seconds", "expected"),
    [
        (0, "ok"),
        (900, "ok"),
        (901, "warning"),
        (1800, "warning"),
        (1801, "critical"),
    ],
)
def test_classify_uses_target_and_double_target_as_boundaries(
    value_seconds: int, expected: str
) -> None:
    assert classify(value_seconds, 900) == expected


@pytest.mark.unit
def test_age_seconds_measures_elapsed_time() -> None:
    # Arrange
    now = datetime(2026, 7, 24, 12, 0, tzinfo=UTC)
    recorded_at = now - timedelta(minutes=7)

    # Act / Assert
    assert age_seconds(recorded_at, now) == 420


@pytest.mark.unit
def test_age_seconds_never_returns_a_negative_age_on_clock_skew() -> None:
    # Arrange: il pod che scrive e quello che legge possono avere clock diversi.
    now = datetime(2026, 7, 24, 12, 0, tzinfo=UTC)
    recorded_in_the_future = now + timedelta(minutes=3)

    # Act / Assert: un RPO negativo sarebbe un dato impossibile mostrato in UI.
    assert age_seconds(recorded_in_the_future, now) == 0
