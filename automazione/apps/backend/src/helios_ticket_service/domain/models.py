from __future__ import annotations

from dataclasses import dataclass, replace
from datetime import datetime
from enum import StrEnum
from uuid import UUID


class DomainValidationError(ValueError):
    """Raised when a ticket invariant is violated."""


class TicketPriority(StrEnum):
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"


class TicketStatus(StrEnum):
    OPEN = "open"
    IN_PROGRESS = "in_progress"
    WAITING_USER = "waiting_user"
    WAITING_THIRD_PARTY = "waiting_third_party"
    SCHEDULED = "scheduled"
    CLOSED = "closed"


@dataclass(frozen=True, slots=True)
class Ticket:
    id: UUID
    title: str
    description: str
    priority: TicketPriority
    status: TicketStatus
    assignee: str | None
    service: str
    environment: str
    created_by: str
    created_at: datetime
    updated_at: datetime

    def __post_init__(self) -> None:
        _validate_length("title", self.title, minimum=3, maximum=160)
        _validate_length("description", self.description, minimum=1, maximum=4000)
        _validate_length("service", self.service, minimum=1, maximum=120)
        _validate_length("environment", self.environment, minimum=1, maximum=80)
        _validate_length("created_by", self.created_by, minimum=1, maximum=255)
        if self.assignee is not None:
            _validate_length("assignee", self.assignee, minimum=1, maximum=255)
        _validate_timestamp(self.created_at)
        _validate_timestamp(self.updated_at)
        if self.updated_at < self.created_at:
            raise DomainValidationError("updated_at cannot precede created_at")

    @classmethod
    def open(
        cls,
        *,
        ticket_id: UUID,
        title: str,
        description: str,
        priority: TicketPriority,
        service: str,
        environment: str,
        created_by: str,
        created_at: datetime,
        assignee: str | None = None,
    ) -> Ticket:
        return cls(
            id=ticket_id,
            title=title.strip(),
            description=description.strip(),
            priority=priority,
            status=TicketStatus.OPEN,
            assignee=assignee.strip() if assignee else None,
            service=service.strip(),
            environment=environment.strip(),
            created_by=created_by,
            created_at=created_at,
            updated_at=created_at,
        )

    def transition(
        self,
        *,
        status: TicketStatus,
        updated_at: datetime,
        assignee: str | None = None,
    ) -> Ticket:
        if self.status is TicketStatus.CLOSED and status is not TicketStatus.CLOSED:
            raise DomainValidationError("closed tickets cannot be reopened")
        return replace(
            self,
            status=status,
            assignee=assignee.strip() if assignee else None,
            updated_at=updated_at,
        )


def _validate_length(name: str, value: str, *, minimum: int, maximum: int) -> None:
    length = len(value.strip()) if isinstance(value, str) else 0
    if not minimum <= length <= maximum:
        raise DomainValidationError(f"{name} must contain between {minimum} and {maximum} chars")


def _validate_timestamp(value: datetime) -> None:
    if value.tzinfo is None or value.utcoffset() is None:
        raise DomainValidationError("ticket timestamps must be timezone-aware")
