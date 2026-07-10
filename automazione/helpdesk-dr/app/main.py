import os
from datetime import datetime, timezone
from typing import Literal

import psycopg
from fastapi import FastAPI, HTTPException, status
from pydantic import BaseModel, Field


DATABASE_URL = os.environ["DATABASE_URL"]
SITE_ROLE = os.environ.get("SITE_ROLE", "unknown")
SITE_NAME = os.environ.get("SITE_NAME", "unknown")
DR_READY_POLICY = os.environ.get("DR_READY_POLICY", "always")
DR_READY_FILE = os.environ.get("DR_READY_FILE", "/dr-state/ready")

app = FastAPI(title="Reverse DR Helpdesk")


class TicketIn(BaseModel):
    title: str = Field(min_length=3, max_length=160)
    description: str = Field(min_length=1, max_length=4000)
    priority: Literal["low", "normal", "high"] = "normal"


def connect():
    return psycopg.connect(DATABASE_URL)


def init_schema():
    with connect() as conn:
        conn.execute(
            """
            create table if not exists tickets (
              id bigserial primary key,
              title text not null,
              description text not null,
              priority text not null,
              status text not null default 'open',
              created_at timestamptz not null default now()
            )
            """
        )


@app.on_event("startup")
def on_startup():
    init_schema()


@app.get("/health")
def health():
    return live()


@app.get("/health/live")
def live():
    with connect() as conn:
        conn.execute("select 1")
    return {
        "status": "ok",
        "site_role": SITE_ROLE,
        "site_name": SITE_NAME,
        "checked_at": datetime.now(timezone.utc).isoformat(),
    }


@app.get("/health/ready")
def ready():
    with connect() as conn:
        conn.execute("select 1")

    if DR_READY_POLICY == "always":
        dr_ready = True
    elif DR_READY_POLICY == "marker":
        dr_ready = os.path.exists(DR_READY_FILE)
    else:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"Unsupported DR_READY_POLICY={DR_READY_POLICY}",
        )

    if not dr_ready:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail={
                "status": "standby",
                "site_role": SITE_ROLE,
                "site_name": SITE_NAME,
                "reason": "DR marker not present",
            },
        )

    return {
        "status": "ready",
        "site_role": SITE_ROLE,
        "site_name": SITE_NAME,
        "dr_ready_policy": DR_READY_POLICY,
        "checked_at": datetime.now(timezone.utc).isoformat(),
    }


@app.get("/version")
def version():
    return {
        "application": "reverse-dr-helpdesk",
        "site_role": SITE_ROLE,
        "site_name": SITE_NAME,
    }


@app.get("/dr-status")
def dr_status():
    with connect() as conn:
        conn.execute("select 1")

    marker_present = os.path.exists(DR_READY_FILE)
    promoted = DR_READY_POLICY == "marker" and marker_present
    active_site = "on-prem" if promoted else SITE_NAME
    mode = "dr" if promoted else "normal"

    return {
        "application": "reverse-dr-helpdesk",
        "mode": mode,
        "active_site": active_site,
        "served_by": SITE_NAME,
        "site_role": SITE_ROLE,
        "dr_ready_policy": DR_READY_POLICY,
        "dr_marker_present": marker_present,
        "ready_for_traffic": DR_READY_POLICY == "always" or marker_present,
        "checked_at": datetime.now(timezone.utc).isoformat(),
    }


@app.post("/tickets", status_code=201)
def create_ticket(ticket: TicketIn):
    with connect() as conn:
        row = conn.execute(
            """
            insert into tickets (title, description, priority)
            values (%s, %s, %s)
            returning id, title, description, priority, status, created_at
            """,
            (ticket.title, ticket.description, ticket.priority),
        ).fetchone()
    return serialize_ticket(row)


@app.get("/tickets")
def list_tickets():
    with connect() as conn:
        rows = conn.execute(
            """
            select id, title, description, priority, status, created_at
            from tickets
            order by id desc
            limit 100
            """
        ).fetchall()
    return [serialize_ticket(row) for row in rows]


@app.patch("/tickets/{ticket_id}/close")
def close_ticket(ticket_id: int):
    with connect() as conn:
        row = conn.execute(
            """
            update tickets
            set status = 'closed'
            where id = %s
            returning id, title, description, priority, status, created_at
            """,
            (ticket_id,),
        ).fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail="Ticket not found")
    return serialize_ticket(row)


def serialize_ticket(row):
    return {
        "id": row[0],
        "title": row[1],
        "description": row[2],
        "priority": row[3],
        "status": row[4],
        "created_at": row[5].isoformat(),
    }
