#!/usr/bin/env bash
# Builds the "Sprout" fixture repository for the split-team-workspaces eval.
#
# Runs in the current (empty) working directory. Deterministic: fixed author,
# committer and dates. No network, no remotes, nothing written outside cwd.
#
# Branches produced:
#   main                     3 commits: plant tracker with owner-scoped plants
#   release/2.3              stale branch off the first main commit (distractor)
#   feature/team-workspaces  9 messy commits on top of main (the PR to split)
set -euo pipefail

if [ -e .git ]; then
  echo "build-fixture.sh: refusing to run inside an existing git repository" >&2
  exit 1
fi

git init -q -b main
git config user.name "Fixture Bot"
git config user.email fixture@example.com
git config commit.gpgsign false
git config core.autocrlf false

commit_at() {
  local when="$1"
  shift
  git add -A
  GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" git commit -q --no-verify "$@"
}

###############################################################################
# main, commit 1: skeleton, users
###############################################################################
mkdir -p sprout/models sprout/templates migrations tests

cat > .gitignore <<'EOF'
__pycache__/
*.py[cod]
*.db
.venv/
.pytest_cache/
*.egg-info/
EOF

cat > pyproject.toml <<'EOF'
[build-system]
requires = ["setuptools>=68"]
build-backend = "setuptools.build_meta"

[project]
name = "sprout"
version = "2.3.0.dev0"
description = "Plant-care tracking for people who forget to water things."
readme = "README.md"
requires-python = ">=3.11"
dependencies = [
    "flask>=3.0",
    "sqlalchemy>=2.0",
]

[project.optional-dependencies]
dev = [
    "pytest>=8.0",
]

[tool.setuptools.packages.find]
include = ["sprout*"]

[tool.pytest.ini_options]
testpaths = ["tests"]
addopts = "-ra --strict-markers"
filterwarnings = ["error::DeprecationWarning:sprout.*"]
EOF

cat > README.md <<'EOF'
# Sprout

Sprout is a small web app for keeping houseplants alive. It tracks each
plant, where it lives and how often it wants water, and keeps a care log of
what you did and when.

Sprout is built for one person looking after their own plants.

## Development

    python -m venv .venv && . .venv/bin/activate
    pip install -e '.[dev]'
    pytest

## Database

Migrations are plain Python files under `migrations/`, applied in filename
order by `sprout.db.apply_migrations`. Each file declares `revision`,
`down_revision`, `upgrade(conn)` and `downgrade(conn)`.

For tests and quick local hacking, `sprout.db.create_all(app)` builds the
schema straight from the models instead.

## Layout

- `sprout/models/` - SQLAlchemy models
- `sprout/auth.py` - loads the signed-in user for each request
- `sprout/templates/` - Jinja templates
EOF

cat > sprout/__init__.py <<'EOF'
"""Sprout: a small plant-care tracker."""
from __future__ import annotations

import importlib

from flask import Blueprint, Flask

from sprout import config as sprout_config
from sprout import db
from sprout.auth import load_current_user

__version__ = "2.3.0.dev0"


def _load_blueprint(spec: str) -> Blueprint:
    """Resolve a ``"package.module:attribute"`` string to a blueprint."""
    module_name, _, attribute = spec.partition(":")
    if not attribute:
        raise ValueError(f"blueprint spec {spec!r} must look like 'module:attribute'")
    blueprint = getattr(importlib.import_module(module_name), attribute)
    if not isinstance(blueprint, Blueprint):
        raise TypeError(f"{spec} is not a Flask Blueprint")
    return blueprint


def create_app(config: dict | None = None) -> Flask:
    """Application factory.

    ``config`` overrides :data:`sprout.config.DEFAULTS`; tests use it to point
    ``DATABASE_URL`` at a throwaway SQLite file. The blueprints to register
    come from :data:`sprout.config.BLUEPRINTS`.
    """
    app = Flask(__name__)
    app.config.update(sprout_config.DEFAULTS)
    if config:
        app.config.update(config)

    db.init_app(app)
    app.before_request(load_current_user)

    for spec in sprout_config.BLUEPRINTS:
        app.register_blueprint(_load_blueprint(spec))
    return app
EOF

cat > sprout/config.py <<'EOF'
"""Static configuration shared by the app factory and a few modules.

Flask settings in ``DEFAULTS`` can be overridden per app through
``create_app(config=...)``; everything else is a plain module constant.
"""

#: Blueprints registered by :func:`sprout.create_app`, as ``"module:attribute"``
#: strings so that importing :mod:`sprout` stays cheap.
BLUEPRINTS: list[str] = []

#: Flask settings applied before any caller overrides.
DEFAULTS = {
    "DATABASE_URL": "sqlite:///sprout.db",
    "SECRET_KEY": "dev-only-change-me",
}
EOF

cat > sprout/db.py <<'EOF'
"""Database wiring for Sprout.

A single scoped session is shared by the whole app. ``init_app`` binds it to
an engine built from ``DATABASE_URL``; the session is removed at the end of
every app context so request state never leaks between requests.
"""
from __future__ import annotations

import importlib.util
from datetime import datetime, timezone
from pathlib import Path

from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine
from sqlalchemy.orm import DeclarativeBase, scoped_session, sessionmaker


class Base(DeclarativeBase):
    """Declarative base for every Sprout model."""


session = scoped_session(sessionmaker(expire_on_commit=False))


def utcnow() -> datetime:
    """Timezone-aware 'now', used for every timestamp column default."""
    return datetime.now(timezone.utc)


def ensure_aware(value: datetime | None) -> datetime | None:
    """SQLite hands back naive datetimes; treat them as UTC."""
    if value is None or value.tzinfo is not None:
        return value
    return value.replace(tzinfo=timezone.utc)


def init_app(app) -> Engine:
    engine = create_engine(app.config["DATABASE_URL"])
    session.configure(bind=engine)
    app.extensions["sprout.engine"] = engine

    @app.teardown_appcontext
    def _remove_session(exc: BaseException | None = None) -> None:
        session.remove()

    return engine


def create_all(app) -> None:
    """Create every table directly from the models (tests and local dev only)."""
    from sprout import models  # noqa: F401  (registers every model on Base)

    Base.metadata.create_all(app.extensions["sprout.engine"])


def _load_migration(path: Path):
    spec = importlib.util.spec_from_file_location(f"sprout_migration_{path.stem}", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load migration {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def apply_migrations(engine: Engine, directory: str | Path = "migrations") -> list[str]:
    """Apply plain-python migrations in filename order.

    Each file defines ``revision``, ``down_revision`` and ``upgrade(conn)``.
    Applied revisions are tracked in the ``schema_revisions`` table. Returns
    the revisions applied by this call.
    """
    with engine.begin() as conn:
        conn.execute(
            text(
                "CREATE TABLE IF NOT EXISTS schema_revisions ("
                " revision VARCHAR(32) PRIMARY KEY,"
                " applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP)"
            )
        )
        applied = set(conn.execute(text("SELECT revision FROM schema_revisions")).scalars())

    newly_applied: list[str] = []
    for path in sorted(Path(directory).glob("[0-9][0-9][0-9][0-9]_*.py")):
        module = _load_migration(path)
        if module.revision in applied:
            continue
        if module.down_revision is not None and module.down_revision not in applied:
            raise RuntimeError(
                f"migration {module.revision} needs {module.down_revision}, which is not applied"
            )
        with engine.begin() as conn:
            module.upgrade(conn)
            conn.execute(
                text("INSERT INTO schema_revisions (revision) VALUES (:revision)"),
                {"revision": module.revision},
            )
        applied.add(module.revision)
        newly_applied.append(module.revision)
    return newly_applied
EOF

cat > sprout/auth.py <<'EOF'
"""Minimal request-scoped user loading.

The session cookie stores the signed-in user's id. Tests and the local CLI may
pass an ``X-Sprout-User`` header instead.
"""
from __future__ import annotations

from functools import wraps

from flask import abort, g, request
from flask import session as http_session

from sprout.db import session
from sprout.models.user import User


def load_current_user() -> None:
    """``before_request`` hook: populate ``g.user`` (or leave it ``None``)."""
    g.user = None
    raw = http_session.get("user_id") or request.headers.get("X-Sprout-User")
    if raw is None:
        return
    try:
        user_id = int(raw)
    except (TypeError, ValueError):
        return
    g.user = session.get(User, user_id)


def login_required(view):
    """Reject anonymous requests with ``401`` before the view runs."""

    @wraps(view)
    def wrapped(*args, **kwargs):
        if g.get("user") is None:
            abort(401)
        return view(*args, **kwargs)

    return wrapped
EOF

cat > sprout/models/__init__.py <<'EOF'
"""All Sprout models, imported here so ``Base.metadata`` sees every table."""
from sprout.models.user import User

__all__ = ["User"]
EOF

cat > sprout/models/user.py <<'EOF'
"""The person using Sprout."""
from __future__ import annotations

from datetime import datetime

from sqlalchemy import DateTime, Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from sprout.db import Base, utcnow


class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    username: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    display_name: Mapped[str] = mapped_column(String(120), nullable=False, default="")
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utcnow
    )

    def __repr__(self) -> str:
        return f"<User {self.id} {self.username!r}>"
EOF

cat > sprout/templates/nav.html <<'EOF'
{# Primary navigation, included from every page layout. #}
<nav class="sprout-nav" aria-label="Primary">
  <a class="sprout-nav__brand" href="/">Sprout</a>
  <ul class="sprout-nav__links">
    <li><a href="/plants">My plants</a></li>
    <li><a href="/care-log">Care log</a></li>
  </ul>
</nav>
EOF

cat > migrations/0001_users.py <<'EOF'
"""Create the users table.

Revision: 0001
Revises: (none)
"""
from sqlalchemy import text

revision = "0001"
down_revision = None


def upgrade(conn) -> None:
    conn.execute(
        text(
            """
            CREATE TABLE users (
                id INTEGER PRIMARY KEY,
                username VARCHAR(64) NOT NULL UNIQUE,
                display_name VARCHAR(120) NOT NULL DEFAULT '',
                created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
            """
        )
    )


def downgrade(conn) -> None:
    conn.execute(text("DROP TABLE users"))
EOF

cat > tests/conftest.py <<'EOF'
"""Shared pytest fixtures for Sprout."""
import pytest

from sprout import create_app, db
from sprout.db import session
from sprout.models.user import User


@pytest.fixture
def app(tmp_path):
    app = create_app(
        {
            "TESTING": True,
            "DATABASE_URL": f"sqlite:///{tmp_path / 'sprout-test.db'}",
            "SECRET_KEY": "test-secret",
        }
    )
    with app.app_context():
        db.create_all(app)
        yield app
        session.remove()


@pytest.fixture
def client(app):
    return app.test_client()


@pytest.fixture
def make_user(app):
    def _make(username="fern", display_name=None):
        user = User(username=username, display_name=display_name or username.title())
        session.add(user)
        session.commit()
        return user

    return _make


@pytest.fixture
def as_user():
    def _headers(user):
        return {"X-Sprout-User": str(user.id)}

    return _headers
EOF

commit_at "2026-01-12T10:00:00+00:00" -m "Initial Sprout skeleton: app factory, db wiring, users"
FIRST_MAIN_COMMIT="$(git rev-parse HEAD)"

###############################################################################
# main, commit 2: plants
###############################################################################
mkdir -p sprout/plants tests/plants


cat > sprout/models/__init__.py <<'EOF'
"""All Sprout models, imported here so ``Base.metadata`` sees every table."""
from sprout.models.care_event import CareEvent
from sprout.models.plant import Plant
from sprout.models.user import User

__all__ = ["CareEvent", "Plant", "User"]
EOF

cat > sprout/models/plant.py <<'EOF'
"""A plant being looked after."""
from __future__ import annotations

from datetime import datetime, timedelta

from sqlalchemy import DateTime, ForeignKey, Integer, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from sprout.db import Base, ensure_aware, utcnow

DEFAULT_WATERING_INTERVAL_DAYS = 7


class Plant(Base):
    __tablename__ = "plants"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    owner_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    species: Mapped[str] = mapped_column(String(120), nullable=False, default="")
    location: Mapped[str] = mapped_column(String(120), nullable=False, default="")
    watering_interval_days: Mapped[int] = mapped_column(
        Integer, nullable=False, default=DEFAULT_WATERING_INTERVAL_DAYS
    )
    last_watered_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utcnow
    )

    owner = relationship("User")

    def is_thirsty(self, now: datetime | None = None) -> bool:
        """True once the watering interval has elapsed (or it was never watered)."""
        if self.last_watered_at is None:
            return True
        now = now or utcnow()
        due = ensure_aware(self.last_watered_at) + timedelta(days=self.watering_interval_days)
        return now >= due

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "owner_id": self.owner_id,
            "name": self.name,
            "species": self.species,
            "location": self.location,
            "watering_interval_days": self.watering_interval_days,
            "last_watered_at": self.last_watered_at.isoformat() if self.last_watered_at else None,
            "thirsty": self.is_thirsty(),
        }

    def __repr__(self) -> str:
        return f"<Plant {self.id} {self.name!r}>"
EOF

cat > sprout/config.py <<'EOF'
"""Static configuration shared by the app factory and a few modules.

Flask settings in ``DEFAULTS`` can be overridden per app through
``create_app(config=...)``; everything else is a plain module constant.
"""

#: Blueprints registered by :func:`sprout.create_app`, as ``"module:attribute"``
#: strings so that importing :mod:`sprout` stays cheap.
BLUEPRINTS: list[str] = [
    "sprout.plants.api:bp",
    "sprout.carelog.api:bp",
]

#: Flask settings applied before any caller overrides.
DEFAULTS = {
    "DATABASE_URL": "sqlite:///sprout.db",
    "SECRET_KEY": "dev-only-change-me",
}

#: Most care-log entries returned by one request.
CARELOG_PAGE_SIZE = 50
EOF

cat > sprout/plants/__init__.py <<'EOF'
"""Plant tracking."""
EOF

cat > sprout/plants/api.py <<'EOF'
"""JSON API for plants.

Every plant has exactly one owner, and users only ever see their own plants.
"""
from __future__ import annotations

from flask import Blueprint, abort, g, jsonify, request
from sqlalchemy import select

from sprout.auth import login_required
from sprout.db import session
from sprout.models.plant import Plant

bp = Blueprint("plants", __name__, url_prefix="/api/plants")

EDITABLE_FIELDS = ("name", "species", "location", "watering_interval_days")
MAX_INTERVAL_DAYS = 365


def _owned_plants():
    """Plants belonging to the current user."""
    return select(Plant).where(Plant.owner_id == g.user.id)


def _load_plant_or_404(plant_id: int) -> Plant:
    plant = session.get(Plant, plant_id)
    if plant is None or plant.owner_id != g.user.id:
        abort(404)
    return plant


def _apply_changes(plant: Plant, payload: dict) -> str | None:
    """Copy editable fields from ``payload``; return an error message or None."""
    for field in EDITABLE_FIELDS:
        if field not in payload:
            continue
        value = payload[field]
        if field == "name":
            value = (value or "").strip()
            if not value:
                return "name cannot be blank"
        if field == "watering_interval_days":
            if not isinstance(value, int) or not 1 <= value <= MAX_INTERVAL_DAYS:
                return f"watering_interval_days must be between 1 and {MAX_INTERVAL_DAYS}"
        setattr(plant, field, value)
    return None


@bp.get("")
@login_required
def list_plants():
    plants = session.scalars(_owned_plants().order_by(Plant.name, Plant.id)).all()
    return jsonify([plant.to_dict() for plant in plants])


@bp.post("")
@login_required
def create_plant():
    payload = request.get_json(silent=True) or {}
    payload.setdefault("name", "")
    plant = Plant(owner_id=g.user.id, name="")
    error = _apply_changes(plant, payload)
    if error:
        return jsonify(error=error), 400
    session.add(plant)
    session.commit()
    return jsonify(plant.to_dict()), 201


@bp.patch("/<int:plant_id>")
@login_required
def update_plant(plant_id: int):
    plant = _load_plant_or_404(plant_id)
    error = _apply_changes(plant, request.get_json(silent=True) or {})
    if error:
        session.rollback()
        return jsonify(error=error), 400
    session.commit()
    return jsonify(plant.to_dict())
EOF

cat > migrations/0002_plants.py <<'EOF'
"""Create the plants and care_events tables.

Revision: 0002
Revises: 0001
"""
from sqlalchemy import text

revision = "0002"
down_revision = "0001"


def upgrade(conn) -> None:
    conn.execute(
        text(
            """
            CREATE TABLE plants (
                id INTEGER PRIMARY KEY,
                owner_id INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
                name VARCHAR(120) NOT NULL,
                species VARCHAR(120) NOT NULL DEFAULT '',
                location VARCHAR(120) NOT NULL DEFAULT '',
                watering_interval_days INTEGER NOT NULL DEFAULT 7,
                last_watered_at TIMESTAMP,
                created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
            """
        )
    )
    conn.execute(text("CREATE INDEX ix_plants_owner_id ON plants (owner_id)"))
    conn.execute(
        text(
            """
            CREATE TABLE care_events (
                id INTEGER PRIMARY KEY,
                plant_id INTEGER NOT NULL REFERENCES plants (id) ON DELETE CASCADE,
                user_id INTEGER NOT NULL REFERENCES users (id),
                action VARCHAR(16) NOT NULL,
                note TEXT NOT NULL DEFAULT '',
                occurred_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
            """
        )
    )
    conn.execute(text("CREATE INDEX ix_care_events_plant_id ON care_events (plant_id)"))


def downgrade(conn) -> None:
    conn.execute(text("DROP INDEX ix_care_events_plant_id"))
    conn.execute(text("DROP TABLE care_events"))
    conn.execute(text("DROP INDEX ix_plants_owner_id"))
    conn.execute(text("DROP TABLE plants"))
EOF

cat > tests/plants/test_plants_api.py <<'EOF'
from sprout.db import session
from sprout.models.plant import Plant


def _create(client, headers, **payload):
    payload.setdefault("name", "Monstera")
    return client.post("/api/plants", json=payload, headers=headers)


def test_requires_login(client):
    assert client.get("/api/plants").status_code == 401


def test_create_and_list(client, make_user, as_user):
    fern = make_user("fern")
    resp = _create(client, as_user(fern), name="Pothos", species="Epipremnum aureum")
    assert resp.status_code == 201
    listed = client.get("/api/plants", headers=as_user(fern)).get_json()
    assert [p["name"] for p in listed] == ["Pothos"]


def test_create_requires_name(client, make_user, as_user):
    fern = make_user("fern")
    resp = _create(client, as_user(fern), name="   ")
    assert resp.status_code == 400
    assert session.query(Plant).count() == 0


def test_list_is_scoped_to_owner(client, make_user, as_user):
    fern, ivy = make_user("fern"), make_user("ivy")
    _create(client, as_user(fern), name="Calathea")
    assert client.get("/api/plants", headers=as_user(ivy)).get_json() == []


def test_update_own_plant(client, make_user, as_user):
    fern = make_user("fern")
    plant_id = _create(client, as_user(fern)).get_json()["id"]
    resp = client.patch(
        f"/api/plants/{plant_id}",
        json={"location": "Kitchen window", "watering_interval_days": 10},
        headers=as_user(fern),
    )
    assert resp.status_code == 200
    assert resp.get_json()["location"] == "Kitchen window"


def test_cannot_update_someone_elses_plant(client, make_user, as_user):
    fern, ivy = make_user("fern"), make_user("ivy")
    plant_id = _create(client, as_user(fern)).get_json()["id"]
    resp = client.patch(f"/api/plants/{plant_id}", json={"name": "Mine"}, headers=as_user(ivy))
    assert resp.status_code == 404


def test_update_rejects_bad_interval(client, make_user, as_user):
    fern = make_user("fern")
    plant_id = _create(client, as_user(fern)).get_json()["id"]
    resp = client.patch(
        f"/api/plants/{plant_id}", json={"watering_interval_days": 0}, headers=as_user(fern)
    )
    assert resp.status_code == 400
EOF

mkdir -p sprout/carelog tests/carelog

cat > sprout/models/care_event.py <<'EOF'
"""One thing done for a plant: watering, feeding, repotting, pruning."""
from __future__ import annotations

from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from sprout.db import Base, utcnow

CARE_ACTIONS = ("watered", "fed", "repotted", "pruned")


class CareEvent(Base):
    __tablename__ = "care_events"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    plant_id: Mapped[int] = mapped_column(
        ForeignKey("plants.id", ondelete="CASCADE"), nullable=False, index=True
    )
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False, index=True)
    action: Mapped[str] = mapped_column(String(16), nullable=False)
    note: Mapped[str] = mapped_column(Text, nullable=False, default="")
    occurred_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utcnow
    )

    plant = relationship("Plant")

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "plant_id": self.plant_id,
            "plant_name": self.plant.name,
            "user_id": self.user_id,
            "action": self.action,
            "note": self.note,
            "occurred_at": self.occurred_at.isoformat(),
        }
EOF

cat > sprout/carelog/__init__.py <<'EOF'
"""The care log: what was done for each plant, and when."""
EOF

cat > sprout/carelog/api.py <<'EOF'
"""JSON API for the care log.

Each entry records one thing someone did for a plant. Logging a watering also
updates the plant's ``last_watered_at`` so thirst tracking stays accurate.
"""
from __future__ import annotations

from flask import Blueprint, abort, g, jsonify, request
from sqlalchemy import select

from sprout.auth import login_required
from sprout.config import CARELOG_PAGE_SIZE
from sprout.db import session, utcnow
from sprout.models.care_event import CARE_ACTIONS, CareEvent
from sprout.models.plant import Plant

bp = Blueprint("carelog", __name__, url_prefix="/api/care-log")


@bp.get("")
@login_required
def list_entries():
    """The current user's most recent care-log entries, newest first."""
    stmt = (
        select(CareEvent)
        .where(CareEvent.user_id == g.user.id)
        .order_by(CareEvent.occurred_at.desc(), CareEvent.id.desc())
        .limit(CARELOG_PAGE_SIZE)
    )
    return jsonify([entry.to_dict() for entry in session.scalars(stmt)])


@bp.post("/<int:plant_id>")
@login_required
def log_care(plant_id: int):
    plant = session.get(Plant, plant_id)
    if plant is None or plant.owner_id != g.user.id:
        abort(404)
    payload = request.get_json(silent=True) or {}
    action = payload.get("action", "watered")
    if action not in CARE_ACTIONS:
        return jsonify(error=f"action must be one of {', '.join(CARE_ACTIONS)}"), 400
    entry = CareEvent(
        plant_id=plant.id,
        user_id=g.user.id,
        action=action,
        note=(payload.get("note") or "").strip(),
        occurred_at=utcnow(),
    )
    if action == "watered":
        plant.last_watered_at = entry.occurred_at
    session.add(entry)
    session.commit()
    return jsonify(entry.to_dict()), 201
EOF

cat > tests/carelog/test_carelog_api.py <<'EOF'
from sprout.db import session
from sprout.models.plant import Plant


def _plant(client, user, as_user, name="Fiddle leaf fig"):
    resp = client.post("/api/plants", json={"name": name}, headers=as_user(user))
    return resp.get_json()["id"]


def test_logging_a_watering_updates_the_plant(client, make_user, as_user):
    fern = make_user("fern")
    plant_id = _plant(client, fern, as_user)
    resp = client.post(f"/api/care-log/{plant_id}", json={"note": "soaked"}, headers=as_user(fern))
    assert resp.status_code == 201
    assert session.get(Plant, plant_id).last_watered_at is not None


def test_rejects_unknown_action(client, make_user, as_user):
    fern = make_user("fern")
    plant_id = _plant(client, fern, as_user)
    resp = client.post(
        f"/api/care-log/{plant_id}", json={"action": "serenaded"}, headers=as_user(fern)
    )
    assert resp.status_code == 400


def test_cannot_log_for_someone_elses_plant(client, make_user, as_user):
    fern, ivy = make_user("fern"), make_user("ivy")
    plant_id = _plant(client, fern, as_user)
    assert client.post(f"/api/care-log/{plant_id}", json={}, headers=as_user(ivy)).status_code == 404


def test_list_is_newest_first(client, make_user, as_user):
    fern = make_user("fern")
    plant_id = _plant(client, fern, as_user)
    for action in ("watered", "fed"):
        client.post(f"/api/care-log/{plant_id}", json={"action": action}, headers=as_user(fern))
    listed = client.get("/api/care-log", headers=as_user(fern)).get_json()
    assert [entry["action"] for entry in listed] == ["fed", "watered"]
EOF

commit_at "2026-01-19T14:30:00+00:00" -m "Add plants and care log: models, migration and JSON APIs"

###############################################################################
# main, commit 3: permissions table
###############################################################################
cat > pyproject.toml <<'EOF'
[build-system]
requires = ["setuptools>=68"]
build-backend = "setuptools.build_meta"

[project]
name = "sprout"
version = "2.4.0.dev0"
description = "Plant-care tracking for people who forget to water things."
readme = "README.md"
requires-python = ">=3.11"
dependencies = [
    "flask>=3.0",
    "sqlalchemy>=2.0",
]

[project.optional-dependencies]
dev = [
    "pytest>=8.0",
]

[tool.setuptools.packages.find]
include = ["sprout*"]

[tool.pytest.ini_options]
testpaths = ["tests"]
addopts = "-ra --strict-markers"
filterwarnings = ["error::DeprecationWarning:sprout.*"]
EOF

cat > sprout/__init__.py <<'EOF'
"""Sprout: a small plant-care tracker."""
from __future__ import annotations

import importlib

from flask import Blueprint, Flask

from sprout import config as sprout_config
from sprout import db
from sprout.auth import load_current_user

__version__ = "2.4.0.dev0"


def _load_blueprint(spec: str) -> Blueprint:
    """Resolve a ``"package.module:attribute"`` string to a blueprint."""
    module_name, _, attribute = spec.partition(":")
    if not attribute:
        raise ValueError(f"blueprint spec {spec!r} must look like 'module:attribute'")
    blueprint = getattr(importlib.import_module(module_name), attribute)
    if not isinstance(blueprint, Blueprint):
        raise TypeError(f"{spec} is not a Flask Blueprint")
    return blueprint


def create_app(config: dict | None = None) -> Flask:
    """Application factory.

    ``config`` overrides :data:`sprout.config.DEFAULTS`; tests use it to point
    ``DATABASE_URL`` at a throwaway SQLite file. The blueprints to register
    come from :data:`sprout.config.BLUEPRINTS`.
    """
    app = Flask(__name__)
    app.config.update(sprout_config.DEFAULTS)
    if config:
        app.config.update(config)

    db.init_app(app)
    app.before_request(load_current_user)

    for spec in sprout_config.BLUEPRINTS:
        app.register_blueprint(_load_blueprint(spec))
    return app
EOF

cat > README.md <<'EOF'
# Sprout

Sprout is a small web app for keeping houseplants alive. It tracks each
plant, where it lives and how often it wants water, and keeps a care log of
what you did and when.

Sprout is built for one person looking after their own plants.

## Development

    python -m venv .venv && . .venv/bin/activate
    pip install -e '.[dev]'
    pytest

## Database

Migrations are plain Python files under `migrations/`, applied in filename
order by `sprout.db.apply_migrations`. Each file declares `revision`,
`down_revision`, `upgrade(conn)` and `downgrade(conn)`.

For tests and quick local hacking, `sprout.db.create_all(app)` builds the
schema straight from the models instead.

## Layout

- `sprout/models/` - SQLAlchemy models
- `sprout/auth.py` - loads the signed-in user for each request
- `sprout/config.py` - blueprint list and other static settings
- `sprout/plants/` - plant JSON API
- `sprout/carelog/` - care-log JSON API
- `sprout/permissions.py` - the permission table and `can()`
- `sprout/templates/` - Jinja templates

## Permissions

Views never check ownership inline. Each protected action has a name such as
`plant:update`, and `sprout.permissions.PERMISSIONS` maps it to a predicate.
Call `can(user, "plant:update", plant)` and add new rules to the table.
EOF

cat > sprout/permissions.py <<'EOF'
"""Central permission table.

Every protected action is named ``<resource>:<verb>``. ``PERMISSIONS`` maps the
action name to a predicate ``(user, obj) -> bool``. Views call :func:`can`
rather than checking ownership inline, so the rules live in one place.
"""
from __future__ import annotations

from typing import Any, Callable

Predicate = Callable[[Any, Any], bool]


def _is_owner(user, plant) -> bool:
    return plant.owner_id == user.id


PERMISSIONS: dict[str, Predicate] = {
    "plant:read": _is_owner,
    "plant:update": _is_owner,
    "plant:delete": _is_owner,
    "plant:water": _is_owner,
}


def can(user, action: str, obj: Any = None) -> bool:
    """Return True if ``user`` may perform ``action`` on ``obj``.

    Anonymous users can do nothing. Unknown actions are a programming error
    and raise ``KeyError`` rather than silently denying.
    """
    if user is None:
        return False
    try:
        predicate = PERMISSIONS[action]
    except KeyError:
        raise KeyError(f"unknown permission {action!r}") from None
    return bool(predicate(user, obj))
EOF

cat > sprout/plants/api.py <<'EOF'
"""JSON API for plants.

Every plant has exactly one owner, and users only ever see their own plants.
"""
from __future__ import annotations

from flask import Blueprint, abort, g, jsonify, request
from sqlalchemy import select

from sprout.auth import login_required
from sprout.db import session
from sprout.models.plant import Plant
from sprout.permissions import can

bp = Blueprint("plants", __name__, url_prefix="/api/plants")

EDITABLE_FIELDS = ("name", "species", "location", "watering_interval_days")
MAX_INTERVAL_DAYS = 365


def _owned_plants():
    """Plants belonging to the current user."""
    return select(Plant).where(Plant.owner_id == g.user.id)


def _load_plant_or_404(plant_id: int) -> Plant:
    plant = session.get(Plant, plant_id)
    if plant is None or not can(g.user, "plant:read", plant):
        abort(404)
    return plant


def _apply_changes(plant: Plant, payload: dict) -> str | None:
    """Copy editable fields from ``payload``; return an error message or None."""
    for field in EDITABLE_FIELDS:
        if field not in payload:
            continue
        value = payload[field]
        if field == "name":
            value = (value or "").strip()
            if not value:
                return "name cannot be blank"
        if field == "watering_interval_days":
            if not isinstance(value, int) or not 1 <= value <= MAX_INTERVAL_DAYS:
                return f"watering_interval_days must be between 1 and {MAX_INTERVAL_DAYS}"
        setattr(plant, field, value)
    return None


@bp.get("")
@login_required
def list_plants():
    plants = session.scalars(_owned_plants().order_by(Plant.name, Plant.id)).all()
    return jsonify([plant.to_dict() for plant in plants])


@bp.post("")
@login_required
def create_plant():
    payload = request.get_json(silent=True) or {}
    payload.setdefault("name", "")
    plant = Plant(owner_id=g.user.id, name="")
    error = _apply_changes(plant, payload)
    if error:
        return jsonify(error=error), 400
    session.add(plant)
    session.commit()
    return jsonify(plant.to_dict()), 201


@bp.patch("/<int:plant_id>")
@login_required
def update_plant(plant_id: int):
    plant = _load_plant_or_404(plant_id)
    if not can(g.user, "plant:update", plant):
        abort(403)
    error = _apply_changes(plant, request.get_json(silent=True) or {})
    if error:
        session.rollback()
        return jsonify(error=error), 400
    session.commit()
    return jsonify(plant.to_dict())
EOF

cat > tests/test_permissions.py <<'EOF'
import pytest

from sprout.models.plant import Plant
from sprout.models.user import User
from sprout.permissions import PERMISSIONS, can


def test_owner_can_update():
    fern = User(id=1, username="fern")
    assert can(fern, "plant:update", Plant(owner_id=1, name="Fig"))


def test_non_owner_cannot_update():
    ivy = User(id=2, username="ivy")
    assert not can(ivy, "plant:update", Plant(owner_id=1, name="Fig"))


def test_anonymous_can_do_nothing():
    assert not can(None, "plant:read", Plant(owner_id=1, name="Fig"))


def test_unknown_action_is_a_bug():
    with pytest.raises(KeyError):
        can(User(id=1, username="fern"), "plant:teleport", None)


def test_every_action_is_namespaced():
    assert all(":" in action for action in PERMISSIONS)
EOF

cat > sprout/carelog/api.py <<'EOF'
"""JSON API for the care log.

Each entry records one thing someone did for a plant. Logging a watering also
updates the plant's ``last_watered_at`` so thirst tracking stays accurate.
"""
from __future__ import annotations

from flask import Blueprint, abort, g, jsonify, request
from sqlalchemy import select

from sprout.auth import login_required
from sprout.config import CARELOG_PAGE_SIZE
from sprout.db import session, utcnow
from sprout.models.care_event import CARE_ACTIONS, CareEvent
from sprout.models.plant import Plant
from sprout.permissions import can

bp = Blueprint("carelog", __name__, url_prefix="/api/care-log")


@bp.get("")
@login_required
def list_entries():
    """The current user's most recent care-log entries, newest first."""
    stmt = (
        select(CareEvent)
        .where(CareEvent.user_id == g.user.id)
        .order_by(CareEvent.occurred_at.desc(), CareEvent.id.desc())
        .limit(CARELOG_PAGE_SIZE)
    )
    return jsonify([entry.to_dict() for entry in session.scalars(stmt)])


@bp.post("/<int:plant_id>")
@login_required
def log_care(plant_id: int):
    plant = session.get(Plant, plant_id)
    if plant is None or not can(g.user, "plant:read", plant):
        abort(404)
    if not can(g.user, "plant:water", plant):
        abort(403)
    payload = request.get_json(silent=True) or {}
    action = payload.get("action", "watered")
    if action not in CARE_ACTIONS:
        return jsonify(error=f"action must be one of {', '.join(CARE_ACTIONS)}"), 400
    entry = CareEvent(
        plant_id=plant.id,
        user_id=g.user.id,
        action=action,
        note=(payload.get("note") or "").strip(),
        occurred_at=utcnow(),
    )
    if action == "watered":
        plant.last_watered_at = entry.occurred_at
    session.add(entry)
    session.commit()
    return jsonify(entry.to_dict()), 201
EOF

cat > tests/carelog/test_carelog_api.py <<'EOF'
from sprout.db import session
from sprout.models.plant import Plant
from sprout.models.user import User
from sprout.permissions import can


def _plant(client, user, as_user, name="Fiddle leaf fig"):
    resp = client.post("/api/plants", json={"name": name}, headers=as_user(user))
    return resp.get_json()["id"]


def test_logging_a_watering_updates_the_plant(client, make_user, as_user):
    fern = make_user("fern")
    plant_id = _plant(client, fern, as_user)
    resp = client.post(f"/api/care-log/{plant_id}", json={"note": "soaked"}, headers=as_user(fern))
    assert resp.status_code == 201
    assert session.get(Plant, plant_id).last_watered_at is not None


def test_rejects_unknown_action(client, make_user, as_user):
    fern = make_user("fern")
    plant_id = _plant(client, fern, as_user)
    resp = client.post(
        f"/api/care-log/{plant_id}", json={"action": "serenaded"}, headers=as_user(fern)
    )
    assert resp.status_code == 400


def test_cannot_log_for_someone_elses_plant(client, make_user, as_user):
    fern, ivy = make_user("fern"), make_user("ivy")
    plant_id = _plant(client, fern, as_user)
    assert client.post(f"/api/care-log/{plant_id}", json={}, headers=as_user(ivy)).status_code == 404


def test_list_is_newest_first(client, make_user, as_user):
    fern = make_user("fern")
    plant_id = _plant(client, fern, as_user)
    for action in ("watered", "fed"):
        client.post(f"/api/care-log/{plant_id}", json={"action": action}, headers=as_user(fern))
    listed = client.get("/api/care-log", headers=as_user(fern)).get_json()
    assert [entry["action"] for entry in listed] == ["fed", "watered"]


def test_only_the_owner_may_water():
    fern, ivy = User(id=1, username="fern"), User(id=2, username="ivy")
    plant = Plant(owner_id=1, name="Fig")
    assert can(fern, "plant:water", plant)
    assert not can(ivy, "plant:water", plant)
EOF

commit_at "2026-02-02T09:15:00+00:00" -m "Route plant and care-log access checks through a central permissions table"

###############################################################################
# release/2.3: stale branch off the first main commit (distractor)
###############################################################################
git checkout -q -b release/2.3 "$FIRST_MAIN_COMMIT"

cat > pyproject.toml <<'EOF'
[build-system]
requires = ["setuptools>=68"]
build-backend = "setuptools.build_meta"

[project]
name = "sprout"
version = "2.3.0"
description = "Plant-care tracking for people who forget to water things."
readme = "README.md"
requires-python = ">=3.11"
dependencies = [
    "flask>=3.0",
    "sqlalchemy>=2.0",
]

[project.optional-dependencies]
dev = [
    "pytest>=8.0",
]

[tool.setuptools.packages.find]
include = ["sprout*"]

[tool.pytest.ini_options]
testpaths = ["tests"]
addopts = "-ra --strict-markers"
filterwarnings = ["error::DeprecationWarning:sprout.*"]
EOF

cat > CHANGELOG.md <<'EOF'
# Changelog

## 2.3.0

- App factory, database wiring and user accounts.
EOF

commit_at "2026-01-26T11:00:00+00:00" -m "Release 2.3.0"

cat > sprout/auth.py <<'EOF'
"""Minimal request-scoped user loading.

The session cookie stores the signed-in user's id. Tests and the local CLI may
pass an ``X-Sprout-User`` header instead.
"""
from __future__ import annotations

from functools import wraps

from flask import abort, g, request
from flask import session as http_session

from sprout.db import session
from sprout.models.user import User


def load_current_user() -> None:
    """``before_request`` hook: populate ``g.user`` (or leave it ``None``)."""
    g.user = None
    raw = http_session.get("user_id") or request.headers.get("X-Sprout-User")
    if raw in (None, ""):
        return
    try:
        user_id = int(raw)
    except (TypeError, ValueError):
        return
    if user_id <= 0:
        return
    g.user = session.get(User, user_id)


def login_required(view):
    """Reject anonymous requests with ``401`` before the view runs."""

    @wraps(view)
    def wrapped(*args, **kwargs):
        if g.get("user") is None:
            abort(401)
        return view(*args, **kwargs)

    return wrapped
EOF

cat > CHANGELOG.md <<'EOF'
# Changelog

## 2.3.1

- Ignore empty or non-positive user ids instead of querying for them.

## 2.3.0

- App factory, database wiring and user accounts.
EOF

commit_at "2026-01-28T16:45:00+00:00" -m "Hotfix 2.3.1: ignore empty user header"

###############################################################################
# feature/team-workspaces
###############################################################################
git checkout -q main
git checkout -q -b feature/team-workspaces

# --- F1: generic audit log --------------------------------------------------
mkdir -p sprout/audit

cat > sprout/audit/__init__.py <<'EOF'
"""Append-only audit trail.

The audit package is deliberately generic: it stores who did what to which
subject, and when. Callers define their own :class:`AuditEvent` subclasses
and hand them to :func:`record`.
"""
from sprout.audit.events import AuditEvent, FieldChanged
from sprout.audit.log import recent, record

__all__ = [
    "AuditEvent",
    "FieldChanged",
    "recent",
    "record",
]
EOF

cat > sprout/audit/events.py <<'EOF'
"""Audit event types.

An event is an immutable description of something a user did. It knows how
to turn itself into a flat record (:meth:`AuditEvent.to_record`) that
:func:`sprout.audit.record` can persist; it knows nothing about storage.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any, ClassVar

KIND_PATTERN = re.compile(r"^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$")


class InvalidEvent(ValueError):
    """Raised when an event cannot be turned into a storable record."""


@dataclass(frozen=True)
class AuditEvent:
    """Something a user did that should be kept on the record.

    Subclasses set ``kind`` (dotted, lowercase: ``"garden.bed_dug"``) and
    override :meth:`subject` and :meth:`details`. ``actor_id`` may be ``None``
    for actions taken by the system itself.
    """

    kind: ClassVar[str] = "event"

    actor_id: int | None

    def subject(self) -> tuple[str | None, int | None]:
        """``(subject_type, subject_id)`` the event is about, if any."""
        return (None, None)

    def details(self) -> dict[str, Any]:
        """Extra JSON-serialisable context stored alongside the event."""
        return {}

    def to_record(self) -> dict[str, Any]:
        """Flatten the event into the fields of an audit entry."""
        if not KIND_PATTERN.match(self.kind):
            raise InvalidEvent(f"{type(self).__name__}.kind {self.kind!r} is not a dotted name")
        subject_type, subject_id = self.subject()
        details = self.details()
        try:
            json.dumps(details)
        except (TypeError, ValueError) as exc:
            raise InvalidEvent(f"details of {self.kind} are not JSON-serialisable") from exc
        return {
            "kind": self.kind,
            "actor_id": self.actor_id,
            "subject_type": subject_type,
            "subject_id": subject_id,
            "details": details,
        }


@dataclass(frozen=True)
class FieldChanged(AuditEvent):
    """A single field on some record changed value.

    Generic enough for any model: ``FieldChanged(actor_id=1,
    subject_type="plant", subject_id=7, field="name", old="Fig", new="Ficus")``.
    """

    kind: ClassVar[str] = "field_changed"

    subject_type: str
    subject_id: int
    field: str
    old: Any
    new: Any

    def subject(self) -> tuple[str | None, int | None]:
        return (self.subject_type, self.subject_id)

    def details(self) -> dict[str, Any]:
        return {"field": self.field, "old": self.old, "new": self.new}
EOF

cat > sprout/audit/log.py <<'EOF'
"""Write and read the audit trail."""
from __future__ import annotations

import json
from datetime import datetime, timedelta

from sqlalchemy import delete, select

from sprout.audit.events import AuditEvent
from sprout.config import AUDIT_RETENTION_DAYS
from sprout.db import session, utcnow
from sprout.models.audit_entry import AuditEntry


def record(event: AuditEvent, *, occurred_at: datetime | None = None) -> AuditEntry:
    """Stage an audit entry for ``event`` in the current session.

    The entry is flushed but not committed: it becomes durable together with
    whatever change the caller is making, or not at all.
    """
    if not isinstance(event, AuditEvent):
        raise TypeError(f"record() expects an AuditEvent, got {type(event).__name__}")
    data = event.to_record()
    entry = AuditEntry(
        occurred_at=occurred_at or utcnow(),
        actor_id=data["actor_id"],
        kind=data["kind"],
        subject_type=data["subject_type"],
        subject_id=data["subject_id"],
        details_json=json.dumps(data["details"], sort_keys=True, separators=(",", ":")),
    )
    session.add(entry)
    session.flush()
    return entry


def recent(actor_id: int, limit: int = 50) -> list[AuditEntry]:
    """The most recent entries recorded for ``actor_id``, newest first."""
    if limit <= 0:
        raise ValueError("limit must be positive")
    stmt = (
        select(AuditEntry)
        .where(AuditEntry.actor_id == actor_id)
        .order_by(AuditEntry.occurred_at.desc(), AuditEntry.id.desc())
        .limit(limit)
    )
    return list(session.scalars(stmt))


def prune(now: datetime | None = None) -> int:
    """Delete entries older than :data:`sprout.config.AUDIT_RETENTION_DAYS`.

    Returns the number of rows removed. Commits: pruning is housekeeping and
    never part of a larger change.
    """
    cutoff = (now or utcnow()) - timedelta(days=AUDIT_RETENTION_DAYS)
    result = session.execute(delete(AuditEntry).where(AuditEntry.occurred_at < cutoff))
    session.commit()
    return result.rowcount
EOF

cat > sprout/models/audit_entry.py <<'EOF'
"""One row of the audit trail."""
from __future__ import annotations

import json
from datetime import datetime
from typing import Any

from sqlalchemy import DateTime, ForeignKey, Index, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from sprout.db import Base, utcnow


class AuditEntry(Base):
    """Append-only: rows are inserted by :func:`sprout.audit.record` and never updated."""

    __tablename__ = "audit_entries"
    __table_args__ = (
        Index("ix_audit_entries_actor_occurred", "actor_id", "occurred_at"),
        Index("ix_audit_entries_subject", "subject_type", "subject_id"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    occurred_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utcnow
    )
    actor_id: Mapped[int | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    kind: Mapped[str] = mapped_column(String(64), nullable=False)
    subject_type: Mapped[str | None] = mapped_column(String(32))
    subject_id: Mapped[int | None] = mapped_column(Integer)
    details_json: Mapped[str] = mapped_column(Text, nullable=False, default="{}")

    @property
    def details(self) -> dict[str, Any]:
        return json.loads(self.details_json or "{}")

    def __repr__(self) -> str:
        return f"<AuditEntry {self.id} {self.kind} actor={self.actor_id}>"
EOF

cat > sprout/models/__init__.py <<'EOF'
"""All Sprout models, imported here so ``Base.metadata`` sees every table."""
from sprout.models.audit_entry import AuditEntry
from sprout.models.care_event import CareEvent
from sprout.models.plant import Plant
from sprout.models.user import User

__all__ = ["AuditEntry", "CareEvent", "Plant", "User"]
EOF

cat > migrations/0003_audit_entries.py <<'EOF'
"""Create the append-only audit_entries table.

Revision: 0003
Revises: 0002
"""
from sqlalchemy import text

revision = "0003"
down_revision = "0002"


def upgrade(conn) -> None:
    conn.execute(
        text(
            """
            CREATE TABLE audit_entries (
                id INTEGER PRIMARY KEY,
                occurred_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                actor_id INTEGER REFERENCES users (id) ON DELETE SET NULL,
                kind VARCHAR(64) NOT NULL,
                subject_type VARCHAR(32),
                subject_id INTEGER,
                details_json TEXT NOT NULL DEFAULT '{}'
            )
            """
        )
    )
    conn.execute(
        text(
            "CREATE INDEX ix_audit_entries_actor_occurred"
            " ON audit_entries (actor_id, occurred_at)"
        )
    )
    conn.execute(
        text("CREATE INDEX ix_audit_entries_subject ON audit_entries (subject_type, subject_id)")
    )


def downgrade(conn) -> None:
    conn.execute(text("DROP INDEX ix_audit_entries_subject"))
    conn.execute(text("DROP INDEX ix_audit_entries_actor_occurred"))
    conn.execute(text("DROP TABLE audit_entries"))
EOF

cat > sprout/config.py <<'EOF'
"""Static configuration shared by the app factory and a few modules.

Flask settings in ``DEFAULTS`` can be overridden per app through
``create_app(config=...)``; everything else is a plain module constant.
"""

#: Blueprints registered by :func:`sprout.create_app`, as ``"module:attribute"``
#: strings so that importing :mod:`sprout` stays cheap.
BLUEPRINTS: list[str] = [
    "sprout.plants.api:bp",
    "sprout.carelog.api:bp",
    "sprout.workspaces.api:bp",
]

#: Flask settings applied before any caller overrides.
DEFAULTS = {
    "DATABASE_URL": "sqlite:///sprout.db",
    "SECRET_KEY": "dev-only-change-me",
}

#: Most care-log entries returned by one request.
CARELOG_PAGE_SIZE = 50

#: Audit entries older than this many days are deleted by
#: :func:`sprout.audit.log.prune`.
AUDIT_RETENTION_DAYS = 90
EOF

commit_at "2026-02-09T10:20:00+00:00" -m "Add generic audit log (events, record/recent/prune, audit_entries table); config tweaks"

# --- F2: workspace + membership models and migrations ----------------------
cat > sprout/models/workspace.py <<'EOF'
"""A shared space whose members look after plants together."""
from __future__ import annotations

from datetime import datetime

from sqlalchemy import Boolean, DateTime, ForeignKey, Integer, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from sprout.db import Base, utcnow


class Workspace(Base):
    __tablename__ = "workspaces"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    name: Mapped[str] = mapped_column(String(80), nullable=False)
    slug: Mapped[str] = mapped_column(String(64), nullable=False, unique=True, index=True)
    is_personal: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    created_by_id: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utcnow
    )

    created_by = relationship("User")
    memberships = relationship(
        "Membership",
        back_populates="workspace",
        cascade="all, delete-orphan",
        order_by="Membership.joined_at",
    )

    def member_ids(self) -> set[int]:
        return {membership.user_id for membership in self.memberships}

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "name": self.name,
            "slug": self.slug,
            "is_personal": self.is_personal,
            "created_by_id": self.created_by_id,
            "member_count": len(self.memberships),
        }

    def __repr__(self) -> str:
        return f"<Workspace {self.id} {self.slug!r}>"
EOF

cat > sprout/models/membership.py <<'EOF'
"""A user's membership (and role) in a workspace."""
from __future__ import annotations

from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Integer, String, UniqueConstraint
from sqlalchemy.orm import Mapped, backref, mapped_column, relationship

from sprout.db import Base, utcnow

#: Roles in ascending order of power. Each role can do everything the roles
#: before it can.
ROLES = ("viewer", "editor", "owner")
ROLE_RANK = {role: rank for rank, role in enumerate(ROLES, start=1)}


class Membership(Base):
    __tablename__ = "memberships"
    __table_args__ = (
        UniqueConstraint("workspace_id", "user_id", name="uq_memberships_workspace_user"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    workspace_id: Mapped[int] = mapped_column(
        ForeignKey("workspaces.id", ondelete="CASCADE"), nullable=False, index=True
    )
    user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    role: Mapped[str] = mapped_column(String(16), nullable=False, default="viewer")
    joined_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utcnow
    )

    workspace = relationship("Workspace", back_populates="memberships")
    user = relationship(
        "User",
        backref=backref("memberships", lazy="selectin", cascade="all, delete-orphan"),
    )

    def has_role(self, minimum: str) -> bool:
        """True if this membership's role is at least ``minimum``."""
        return ROLE_RANK[self.role] >= ROLE_RANK[minimum]

    def to_dict(self) -> dict:
        return {
            "user_id": self.user_id,
            "username": self.user.username,
            "display_name": self.user.display_name,
            "role": self.role,
            "joined_at": self.joined_at.isoformat() if self.joined_at else None,
        }

    def __repr__(self) -> str:
        return f"<Membership ws={self.workspace_id} user={self.user_id} {self.role}>"
EOF

cat > sprout/models/__init__.py <<'EOF'
"""All Sprout models, imported here so ``Base.metadata`` sees every table."""
from sprout.models.audit_entry import AuditEntry
from sprout.models.care_event import CareEvent
from sprout.models.membership import Membership
from sprout.models.plant import Plant
from sprout.models.user import User
from sprout.models.workspace import Workspace

__all__ = ["AuditEntry", "CareEvent", "Membership", "Plant", "User", "Workspace"]
EOF

cat > migrations/0004_workspaces.py <<'EOF'
"""Create the workspaces table.

Revision: 0004
Revises: 0003
"""
from sqlalchemy import text

revision = "0004"
down_revision = "0003"


def upgrade(conn) -> None:
    conn.execute(
        text(
            """
            CREATE TABLE workspaces (
                id INTEGER PRIMARY KEY,
                name VARCHAR(80) NOT NULL,
                slug VARCHAR(64) NOT NULL UNIQUE,
                is_personal BOOLEAN NOT NULL DEFAULT 0,
                created_by_id INTEGER NOT NULL REFERENCES users (id),
                created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
            """
        )
    )
    conn.execute(text("CREATE INDEX ix_workspaces_slug ON workspaces (slug)"))


def downgrade(conn) -> None:
    conn.execute(text("DROP INDEX ix_workspaces_slug"))
    conn.execute(text("DROP TABLE workspaces"))
EOF

cat > migrations/0005_memberships.py <<'EOF'
"""Create the memberships table linking users to workspaces.

Revision: 0005
Revises: 0004  (needs the workspaces table)
"""
from sqlalchemy import text

revision = "0005"
down_revision = "0004"


def upgrade(conn) -> None:
    conn.execute(
        text(
            """
            CREATE TABLE memberships (
                id INTEGER PRIMARY KEY,
                workspace_id INTEGER NOT NULL REFERENCES workspaces (id) ON DELETE CASCADE,
                user_id INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
                role VARCHAR(16) NOT NULL DEFAULT 'viewer',
                joined_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                CONSTRAINT uq_memberships_workspace_user UNIQUE (workspace_id, user_id),
                CONSTRAINT ck_memberships_role CHECK (role IN ('viewer', 'editor', 'owner'))
            )
            """
        )
    )
    conn.execute(text("CREATE INDEX ix_memberships_workspace_id ON memberships (workspace_id)"))
    conn.execute(text("CREATE INDEX ix_memberships_user_id ON memberships (user_id)"))


def downgrade(conn) -> None:
    conn.execute(text("DROP INDEX ix_memberships_user_id"))
    conn.execute(text("DROP INDEX ix_memberships_workspace_id"))
    conn.execute(text("DROP TABLE memberships"))
EOF

commit_at "2026-02-10T15:05:00+00:00" -m "WIP workspace + membership models and migrations"

# --- F3: workspace service, API, audit workspace events --------------------
mkdir -p sprout/workspaces

cat > pyproject.toml <<'EOF'
[build-system]
requires = ["setuptools>=68"]
build-backend = "setuptools.build_meta"

[project]
name = "sprout"
version = "2.4.0.dev0"
description = "Plant-care tracking for people who forget to water things."
readme = "README.md"
requires-python = ">=3.11"
dependencies = [
    "flask>=3.0",
    "python-slugify>=8.0",
    "sqlalchemy>=2.0",
]

[project.optional-dependencies]
dev = [
    "pytest>=8.0",
]

[tool.setuptools.packages.find]
include = ["sprout*"]

[tool.pytest.ini_options]
testpaths = ["tests"]
addopts = "-ra --strict-markers"
filterwarnings = ["error::DeprecationWarning:sprout.*"]
EOF


cat > sprout/audit/workspace_events.py <<'EOF'
"""Audit events for workspace membership changes and plant moves.

These build on the generic :class:`~sprout.audit.events.AuditEvent` and are
constructed from a live :class:`~sprout.models.workspace.Workspace`, so the
recorded details always carry the workspace id and slug.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any, ClassVar

from sprout.audit.events import AuditEvent
from sprout.models.workspace import Workspace


@dataclass(frozen=True)
class WorkspaceEvent(AuditEvent):
    """Base for events that happen inside a single workspace."""

    kind: ClassVar[str] = "workspace.event"

    workspace_id: int
    workspace_slug: str

    @classmethod
    def for_workspace(cls, actor_id: int | None, workspace: Workspace, **fields: Any):
        """Build the event from a workspace row (which must already have an id)."""
        if not isinstance(workspace, Workspace):
            raise TypeError(f"expected a Workspace, got {type(workspace).__name__}")
        if workspace.id is None:
            raise ValueError("flush the workspace before recording events about it")
        return cls(
            actor_id=actor_id,
            workspace_id=workspace.id,
            workspace_slug=workspace.slug,
            **fields,
        )

    def subject(self) -> tuple[str | None, int | None]:
        return ("workspace", self.workspace_id)

    def details(self) -> dict[str, Any]:
        return {"workspace_id": self.workspace_id, "workspace_slug": self.workspace_slug}


@dataclass(frozen=True)
class MemberAdded(WorkspaceEvent):
    """``actor_id`` added ``member_id`` to the workspace with ``role``."""

    kind: ClassVar[str] = "workspace.member_added"

    member_id: int
    role: str

    def details(self) -> dict[str, Any]:
        return {**super().details(), "member_id": self.member_id, "role": self.role}


@dataclass(frozen=True)
class MemberRemoved(WorkspaceEvent):
    """``actor_id`` removed ``member_id`` from the workspace."""

    kind: ClassVar[str] = "workspace.member_removed"

    member_id: int

    def details(self) -> dict[str, Any]:
        return {**super().details(), "member_id": self.member_id}


@dataclass(frozen=True)
class PlantMoved(WorkspaceEvent):
    """A plant moved into this workspace (from ``from_workspace_id``, if any)."""

    kind: ClassVar[str] = "workspace.plant_moved"

    plant_id: int
    from_workspace_id: int | None

    def subject(self) -> tuple[str | None, int | None]:
        return ("plant", self.plant_id)

    def details(self) -> dict[str, Any]:
        return {
            **super().details(),
            "plant_id": self.plant_id,
            "from_workspace_id": self.from_workspace_id,
        }
EOF

cat > sprout/audit/__init__.py <<'EOF'
"""Append-only audit trail.

The audit package is deliberately generic: it stores who did what to which
subject, and when. Callers define their own :class:`AuditEvent` subclasses
and hand them to :func:`record`.
"""
from sprout.audit.events import AuditEvent, FieldChanged
from sprout.audit.log import recent, record

# Convenience: make the workspace events importable from ``sprout.audit``.
from sprout.audit.workspace_events import MemberAdded, MemberRemoved, PlantMoved

__all__ = [
    "AuditEvent",
    "FieldChanged",
    "MemberAdded",
    "MemberRemoved",
    "PlantMoved",
    "recent",
    "record",
]
EOF

cat > sprout/workspaces/__init__.py <<'EOF'
"""Shared workspaces: groups of users looking after plants together."""
EOF

cat > sprout/workspaces/service.py <<'EOF'
"""Workspace lifecycle: creation, membership changes and lookups.

Every membership change is written to the audit log in the same transaction
as the change itself, so the audit trail can never drift from reality.
"""
from __future__ import annotations

from slugify import slugify
from sqlalchemy import func, select

from sprout.audit import MemberAdded, MemberRemoved, record
from sprout.db import session
from sprout.models.membership import ROLES, Membership
from sprout.models.user import User
from sprout.models.workspace import Workspace

MAX_NAME_LENGTH = 80
SLUG_MAX_LENGTH = 48


class WorkspaceError(Exception):
    """Base class for workspace rule violations surfaced to API callers."""


class InvalidName(WorkspaceError):
    pass


class UnknownRole(WorkspaceError):
    pass


class AlreadyMember(WorkspaceError):
    pass


class NotAMember(WorkspaceError):
    pass


class LastOwner(WorkspaceError):
    """Raised when a change would leave a workspace with no owner."""


def _clean_name(name: str) -> str:
    name = (name or "").strip()
    if not name:
        raise InvalidName("workspace name cannot be blank")
    if len(name) > MAX_NAME_LENGTH:
        raise InvalidName(f"workspace name must be at most {MAX_NAME_LENGTH} characters")
    return name


def _check_role(role: str) -> str:
    if role not in ROLES:
        raise UnknownRole(f"unknown role {role!r}; expected one of {', '.join(ROLES)}")
    return role


def unique_slug(name: str) -> str:
    """A URL-safe slug for ``name`` that no other workspace uses yet."""
    base = slugify(name, max_length=SLUG_MAX_LENGTH, word_boundary=True) or "workspace"
    candidate = base
    suffix = 2
    while session.scalar(select(Workspace.id).where(Workspace.slug == candidate)) is not None:
        candidate = f"{base}-{suffix}"
        suffix += 1
    return candidate


def get_by_slug(slug: str) -> Workspace | None:
    return session.scalar(select(Workspace).where(Workspace.slug == slug))


def workspaces_for(user: User) -> list[Workspace]:
    """Every workspace ``user`` belongs to, personal one first, then by name."""
    stmt = (
        select(Workspace)
        .join(Membership, Membership.workspace_id == Workspace.id)
        .where(Membership.user_id == user.id)
        .order_by(Workspace.is_personal.desc(), Workspace.name)
    )
    return list(session.scalars(stmt))


def membership_for(workspace: Workspace, user: User | None) -> Membership | None:
    if user is None:
        return None
    return session.scalar(
        select(Membership).where(
            Membership.workspace_id == workspace.id,
            Membership.user_id == user.id,
        )
    )


def _owner_count(workspace: Workspace) -> int:
    return session.scalar(
        select(func.count(Membership.id)).where(
            Membership.workspace_id == workspace.id,
            Membership.role == "owner",
        )
    )


def create_workspace(creator: User, name: str, *, personal: bool = False) -> Workspace:
    """Create a workspace with ``creator`` as its first owner."""
    name = _clean_name(name)
    workspace = Workspace(
        name=name,
        slug=unique_slug(name),
        created_by_id=creator.id,
        is_personal=personal,
    )
    session.add(workspace)
    session.flush()
    session.add(Membership(workspace_id=workspace.id, user_id=creator.id, role="owner"))
    record(MemberAdded.for_workspace(creator.id, workspace, member_id=creator.id, role="owner"))
    session.commit()
    return workspace


def personal_workspace_for(user: User) -> Workspace:
    """The user's personal workspace, created on first use."""
    existing = session.scalar(
        select(Workspace).where(
            Workspace.created_by_id == user.id,
            Workspace.is_personal.is_(True),
        )
    )
    if existing is not None:
        return existing
    label = user.display_name or user.username
    return create_workspace(user, f"{label}'s plants", personal=True)


def add_member(
    workspace: Workspace,
    actor: User,
    user: User,
    role: str = "viewer",
    *,
    commit: bool = True,
) -> Membership:
    """Add ``user`` to ``workspace``. ``actor`` is who made the change."""
    _check_role(role)
    if membership_for(workspace, user) is not None:
        raise AlreadyMember(f"{user.username} is already a member of {workspace.name}")
    membership = Membership(workspace_id=workspace.id, user_id=user.id, role=role)
    session.add(membership)
    session.flush()
    record(MemberAdded.for_workspace(actor.id, workspace, member_id=user.id, role=role))
    if commit:
        session.commit()
    return membership


def remove_member(workspace: Workspace, actor: User, user: User) -> None:
    """Remove ``user`` from ``workspace``; the last owner cannot be removed."""
    membership = membership_for(workspace, user)
    if membership is None:
        raise NotAMember(f"{user.username} is not a member of {workspace.name}")
    if membership.role == "owner" and _owner_count(workspace) == 1:
        raise LastOwner("a workspace needs at least one owner")
    session.delete(membership)
    record(MemberRemoved.for_workspace(actor.id, workspace, member_id=user.id))
    session.commit()
EOF

cat > sprout/workspaces/api.py <<'EOF'
"""HTTP routes for workspaces and their members.

JSON in, JSON out. Rule violations raised by :mod:`sprout.workspaces.service`
become ``409`` responses via :func:`_workspace_error`. Workspaces the current
user does not belong to always look like ``404``, never ``403``.
"""
from __future__ import annotations

from flask import Blueprint, abort, g, jsonify, request
from sqlalchemy import select

from sprout.auth import login_required
from sprout.db import session
from sprout.models.user import User
from sprout.workspaces import service

bp = Blueprint("workspaces", __name__, url_prefix="/workspaces")


def _workspace_or_404(slug: str):
    """Load a workspace the current user belongs to, or abort with 404."""
    workspace = service.get_by_slug(slug)
    if workspace is None or service.membership_for(workspace, g.user) is None:
        abort(404)
    return workspace


def _require_role(workspace, minimum: str):
    """The current user's membership, if their role is at least ``minimum``."""
    membership = service.membership_for(workspace, g.user)
    if membership is None:
        abort(404)
    if not membership.has_role(minimum):
        abort(403)
    return membership


def _user_or_404(user_id: int) -> User:
    user = session.get(User, user_id)
    if user is None:
        abort(404)
    return user


@bp.errorhandler(service.WorkspaceError)
def _workspace_error(exc: service.WorkspaceError):
    return jsonify(error=str(exc), code=type(exc).__name__), 409


@bp.get("")
@login_required
def list_workspaces():
    return jsonify([workspace.to_dict() for workspace in service.workspaces_for(g.user)])


@bp.post("")
@login_required
def create_workspace():
    payload = request.get_json(silent=True) or {}
    workspace = service.create_workspace(g.user, payload.get("name", ""))
    return jsonify(workspace.to_dict()), 201


@bp.get("/<slug>")
@login_required
def show_workspace(slug: str):
    workspace = _workspace_or_404(slug)
    data = workspace.to_dict()
    data["members"] = [membership.to_dict() for membership in workspace.memberships]
    return jsonify(data)


@bp.post("/<slug>/members")
@login_required
def add_member(slug: str):
    workspace = _workspace_or_404(slug)
    _require_role(workspace, "owner")
    payload = request.get_json(silent=True) or {}
    username = (payload.get("username") or "").strip()
    user = session.scalar(select(User).where(User.username == username))
    if user is None:
        return jsonify(error=f"no user named {username!r}"), 404
    membership = service.add_member(workspace, g.user, user, role=payload.get("role", "viewer"))
    return jsonify(membership.to_dict()), 201


@bp.delete("/<slug>/members/<int:user_id>")
@login_required
def remove_member(slug: str, user_id: int):
    workspace = _workspace_or_404(slug)
    target = _user_or_404(user_id)
    if target.id != g.user.id:
        # Anyone may leave; only owners may remove other people.
        _require_role(workspace, "owner")
    service.remove_member(workspace, g.user, target)
    return "", 204
EOF

commit_at "2026-02-12T11:40:00+00:00" -m "Workspace service + routes; audit events for membership changes"

# --- F4: scope plants to workspaces ----------------------------------------
cat > migrations/0006_plants_workspace_id.py <<'EOF'
"""Scope plants to workspaces.

Adds a nullable ``plants.workspace_id`` pointing at ``workspaces`` and
backfills it: every existing user gets a personal workspace (with themselves
as owner), and all of their plants move into it.

Revision: 0006
Revises: 0005  (needs workspaces from 0004 and memberships from 0005)
"""
from sqlalchemy import text

revision = "0006"
down_revision = "0005"


def upgrade(conn) -> None:
    conn.execute(
        text(
            "ALTER TABLE plants ADD COLUMN workspace_id INTEGER"
            " REFERENCES workspaces (id) ON DELETE SET NULL"
        )
    )
    conn.execute(text("CREATE INDEX ix_plants_workspace_id ON plants (workspace_id)"))

    users = conn.execute(text("SELECT id, username, display_name FROM users ORDER BY id")).all()
    for user_id, username, display_name in users:
        label = display_name or username
        workspace_id = conn.execute(
            text(
                "INSERT INTO workspaces (name, slug, is_personal, created_by_id)"
                " VALUES (:name, :slug, 1, :user_id) RETURNING id"
            ),
            {"name": f"{label}'s plants", "slug": f"{username.lower()}-personal", "user_id": user_id},
        ).scalar_one()
        conn.execute(
            text(
                "INSERT INTO memberships (workspace_id, user_id, role)"
                " VALUES (:workspace_id, :user_id, 'owner')"
            ),
            {"workspace_id": workspace_id, "user_id": user_id},
        )
        conn.execute(
            text("UPDATE plants SET workspace_id = :workspace_id WHERE owner_id = :user_id"),
            {"workspace_id": workspace_id, "user_id": user_id},
        )


def downgrade(conn) -> None:
    conn.execute(text("DROP INDEX ix_plants_workspace_id"))
    conn.execute(text("ALTER TABLE plants DROP COLUMN workspace_id"))
    conn.execute(
        text(
            "DELETE FROM memberships WHERE workspace_id IN"
            " (SELECT id FROM workspaces WHERE is_personal = 1)"
        )
    )
    conn.execute(text("DELETE FROM workspaces WHERE is_personal = 1"))
EOF

cat > sprout/models/plant.py <<'EOF'
"""A plant being looked after."""
from __future__ import annotations

from datetime import datetime, timedelta

from sqlalchemy import DateTime, ForeignKey, Integer, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from sprout.db import Base, ensure_aware, utcnow

DEFAULT_WATERING_INTERVAL_DAYS = 7


class Plant(Base):
    __tablename__ = "plants"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    owner_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    # Nullable only until migration 0006 has backfilled every row.
    workspace_id: Mapped[int | None] = mapped_column(
        ForeignKey("workspaces.id", ondelete="SET NULL"), nullable=True, index=True
    )
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    species: Mapped[str] = mapped_column(String(120), nullable=False, default="")
    location: Mapped[str] = mapped_column(String(120), nullable=False, default="")
    watering_interval_days: Mapped[int] = mapped_column(
        Integer, nullable=False, default=DEFAULT_WATERING_INTERVAL_DAYS
    )
    last_watered_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utcnow
    )

    owner = relationship("User")
    workspace = relationship("Workspace")

    def is_thirsty(self, now: datetime | None = None) -> bool:
        """True once the watering interval has elapsed (or it was never watered)."""
        if self.last_watered_at is None:
            return True
        now = now or utcnow()
        due = ensure_aware(self.last_watered_at) + timedelta(days=self.watering_interval_days)
        return now >= due

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "owner_id": self.owner_id,
            "workspace_id": self.workspace_id,
            "name": self.name,
            "species": self.species,
            "location": self.location,
            "watering_interval_days": self.watering_interval_days,
            "last_watered_at": self.last_watered_at.isoformat() if self.last_watered_at else None,
            "thirsty": self.is_thirsty(),
        }

    def __repr__(self) -> str:
        return f"<Plant {self.id} {self.name!r}>"
EOF

cat > sprout/plants/api.py <<'EOF'
"""JSON API for plants.

Plants live in workspaces. A user sees every plant in every workspace they
belong to; changing a plant needs at least the ``editor`` role there. Plants
created without an explicit workspace land in the user's personal workspace.
"""
from __future__ import annotations

from flask import Blueprint, abort, g, jsonify, request
from sqlalchemy import select

from sprout.audit import PlantMoved, record
from sprout.auth import login_required
from sprout.db import session
from sprout.models.membership import Membership
from sprout.models.plant import Plant
from sprout.permissions import actor_for, can
from sprout.workspaces import service as workspace_service

bp = Blueprint("plants", __name__, url_prefix="/api/plants")

EDITABLE_FIELDS = ("name", "species", "location", "watering_interval_days")
MAX_INTERVAL_DAYS = 365


def _actor():
    return actor_for(g.user)


def _visible_plants():
    """Plants in any workspace the current user is a member of."""
    member_of = select(Membership.workspace_id).where(Membership.user_id == g.user.id)
    return select(Plant).where(Plant.workspace_id.in_(member_of))


def _load_plant_or_404(plant_id: int) -> Plant:
    plant = session.get(Plant, plant_id)
    if plant is None or not can(_actor(), "plant:read", plant):
        abort(404)
    return plant


def _workspace_or_404(slug: str):
    workspace = workspace_service.get_by_slug(slug)
    if workspace is None or not can(_actor(), "workspace:read", workspace):
        abort(404)
    return workspace


def _apply_changes(plant: Plant, payload: dict) -> str | None:
    """Copy editable fields from ``payload``; return an error message or None."""
    for field in EDITABLE_FIELDS:
        if field not in payload:
            continue
        value = payload[field]
        if field == "name":
            value = (value or "").strip()
            if not value:
                return "name cannot be blank"
        if field == "watering_interval_days":
            if not isinstance(value, int) or not 1 <= value <= MAX_INTERVAL_DAYS:
                return f"watering_interval_days must be between 1 and {MAX_INTERVAL_DAYS}"
        setattr(plant, field, value)
    return None


@bp.get("")
@login_required
def list_plants():
    stmt = _visible_plants()
    slug = request.args.get("workspace")
    if slug:
        workspace = _workspace_or_404(slug)
        stmt = stmt.where(Plant.workspace_id == workspace.id)
    plants = session.scalars(stmt.order_by(Plant.name, Plant.id)).all()
    return jsonify([plant.to_dict() for plant in plants])


@bp.post("")
@login_required
def create_plant():
    payload = request.get_json(silent=True) or {}
    payload.setdefault("name", "")
    if payload.get("workspace"):
        workspace = _workspace_or_404(payload["workspace"])
    else:
        workspace = workspace_service.personal_workspace_for(g.user)
    if not can(_actor(), "workspace:add_plant", workspace):
        abort(403)
    plant = Plant(owner_id=g.user.id, workspace_id=workspace.id, name="")
    error = _apply_changes(plant, payload)
    if error:
        return jsonify(error=error), 400
    session.add(plant)
    session.commit()
    return jsonify(plant.to_dict()), 201


@bp.patch("/<int:plant_id>")
@login_required
def update_plant(plant_id: int):
    plant = _load_plant_or_404(plant_id)
    if not can(_actor(), "plant:update", plant):
        abort(403)
    error = _apply_changes(plant, request.get_json(silent=True) or {})
    if error:
        session.rollback()
        return jsonify(error=error), 400
    session.commit()
    return jsonify(plant.to_dict())


@bp.post("/<int:plant_id>/move")
@login_required
def move_plant(plant_id: int):
    """Move a plant into another workspace the user can add plants to."""
    plant = _load_plant_or_404(plant_id)
    payload = request.get_json(silent=True) or {}
    target = _workspace_or_404(payload.get("workspace") or "")
    actor = _actor()
    if not can(actor, "plant:update", plant) or not can(actor, "workspace:add_plant", target):
        abort(403)
    if target.id == plant.workspace_id:
        return jsonify(plant.to_dict())
    source_id = plant.workspace_id
    plant.workspace_id = target.id
    record(
        PlantMoved.for_workspace(
            g.user.id, target, plant_id=plant.id, from_workspace_id=source_id
        )
    )
    session.commit()
    return jsonify(plant.to_dict())
EOF

cat > sprout/permissions.py <<'EOF'
"""Central permission table.

Every protected action is named ``<resource>:<verb>``. ``PERMISSIONS`` maps the
action name to a predicate ``(actor, obj) -> bool``. Views call :func:`can`
rather than checking ownership inline, so the rules live in one place.

Callers pass an :class:`Actor`, not a bare user: the actor carries the user
plus, when the caller already has it, their membership in the workspace the
request is about, which saves a query per check.

Plants and workspaces are governed by workspace roles (see
:data:`sprout.models.membership.ROLE_RANK`): an actor may act on an object when
their role in the object's workspace is at least the role the action needs.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable

from sqlalchemy import select

from sprout.db import session
from sprout.models.membership import ROLE_RANK, Membership
from sprout.models.user import User


@dataclass(frozen=True)
class Actor:
    """The user performing an action, plus an optional pre-loaded membership."""

    user: User
    membership: Membership | None = None

    @property
    def id(self) -> int:
        return self.user.id

    def role_in(self, workspace_id: int | None) -> str | None:
        """The actor's role in ``workspace_id``, or ``None`` if not a member."""
        if workspace_id is None:
            return None
        if self.membership is not None and self.membership.workspace_id == workspace_id:
            return self.membership.role
        return session.scalar(
            select(Membership.role).where(
                Membership.workspace_id == workspace_id,
                Membership.user_id == self.user.id,
            )
        )


def actor_for(user: User | None, workspace=None) -> Actor | None:
    """Wrap ``user`` as an :class:`Actor`, preloading their membership in ``workspace``."""
    if user is None:
        return None
    membership = None
    if workspace is not None:
        membership = session.scalar(
            select(Membership).where(
                Membership.workspace_id == workspace.id,
                Membership.user_id == user.id,
            )
        )
    return Actor(user=user, membership=membership)


Predicate = Callable[[Actor, Any], bool]


def _rank(role: str | None) -> int:
    return ROLE_RANK.get(role, 0) if role else 0


def _is_owner(actor: Actor, plant) -> bool:
    return plant.owner_id == actor.id


def _plant_role_at_least(minimum: str) -> Predicate:
    needed = ROLE_RANK[minimum]

    def predicate(actor: Actor, plant) -> bool:
        if plant.workspace_id is None:
            # Rows not yet backfilled by migration 0006 fall back to ownership.
            return _is_owner(actor, plant)
        return _rank(actor.role_in(plant.workspace_id)) >= needed

    predicate.__name__ = f"plant_role_at_least_{minimum}"
    return predicate


def _workspace_role_at_least(minimum: str) -> Predicate:
    needed = ROLE_RANK[minimum]

    def predicate(actor: Actor, workspace) -> bool:
        return _rank(actor.role_in(workspace.id)) >= needed

    predicate.__name__ = f"workspace_role_at_least_{minimum}"
    return predicate


PERMISSIONS: dict[str, Predicate] = {
    "plant:read": _plant_role_at_least("viewer"),
    "plant:update": _plant_role_at_least("editor"),
    "plant:delete": _plant_role_at_least("editor"),
    "plant:water": _plant_role_at_least("editor"),
    "workspace:read": _workspace_role_at_least("viewer"),
    "workspace:add_plant": _workspace_role_at_least("editor"),
    "workspace:manage_members": _workspace_role_at_least("owner"),
}


def can(actor: Actor | None, action: str, obj: Any = None) -> bool:
    """Return True if ``actor`` may perform ``action`` on ``obj``.

    Anonymous callers (``None``) can do nothing. Passing a bare ``User`` is a
    programming error: wrap it with :func:`actor_for` first. Unknown actions
    raise ``KeyError`` rather than silently denying.
    """
    if actor is None:
        return False
    if not isinstance(actor, Actor):
        raise TypeError(f"can() expects an Actor, got {type(actor).__name__}; use actor_for()")
    try:
        predicate = PERMISSIONS[action]
    except KeyError:
        raise KeyError(f"unknown permission {action!r}") from None
    return bool(predicate(actor, obj))


# --- Invite links ------------------------------------------------------------


def _invite_is_usable(actor: Actor, invite) -> bool:
    """Anyone signed in may accept a live invite, unless they already belong."""
    return invite.is_usable() and actor.role_in(invite.workspace_id) is None


PERMISSIONS.update(
    {
        "invite:create": _workspace_role_at_least("owner"),
        "invite:revoke": _workspace_role_at_least("owner"),
        "invite:accept": _invite_is_usable,
    }
)
EOF

cat > tests/conftest.py <<'EOF'
"""Shared pytest fixtures for Sprout."""
import secrets
from datetime import datetime, timedelta, timezone

import pytest

from sprout import create_app, db
from sprout.db import session
from sprout.models.invite import Invite
from sprout.models.user import User
from sprout.workspaces.invites import sign_invite


@pytest.fixture
def app(tmp_path):
    app = create_app(
        {
            "TESTING": True,
            "DATABASE_URL": f"sqlite:///{tmp_path / 'sprout-test.db'}",
            "SECRET_KEY": "test-secret",
        }
    )
    with app.app_context():
        db.create_all(app)
        yield app
        session.remove()


@pytest.fixture
def client(app):
    return app.test_client()


@pytest.fixture
def make_user(app):
    def _make(username="fern", display_name=None):
        user = User(username=username, display_name=display_name or username.title())
        session.add(user)
        session.commit()
        return user

    return _make


@pytest.fixture
def make_workspace(app):
    """Create a workspace owned by ``owner`` with optional ``(user, role)`` members."""
    from sprout.workspaces import service

    def _make(owner, name="Balcony garden", members=()):
        workspace = service.create_workspace(owner, name)
        for user, role in members:
            service.add_member(workspace, owner, user, role=role)
        return workspace

    return _make


@pytest.fixture
def as_user():
    def _headers(user):
        return {"X-Sprout-User": str(user.id)}

    return _headers


@pytest.fixture
def invite_token(app):
    """``invite_token(workspace, inviter, role=...)`` -> a signed invite link token.

    Writes the invite row directly, so accept-flow tests do not depend on the
    create-invite route.
    """

    def _make(workspace, inviter, role="viewer", max_uses=1):
        invite = Invite(
            workspace_id=workspace.id,
            created_by_id=inviter.id,
            role=role,
            nonce=secrets.token_urlsafe(24),
            max_uses=max_uses,
            expires_at=datetime.now(timezone.utc) + timedelta(days=1),
        )
        session.add(invite)
        session.commit()
        return sign_invite(invite)

    return _make
EOF

cat > tests/plants/test_plants_api.py <<'EOF'
from sprout.audit import PlantMoved
from sprout.db import session
from sprout.models.audit_entry import AuditEntry
from sprout.models.plant import Plant


def _create(client, headers, **payload):
    payload.setdefault("name", "Monstera")
    return client.post("/api/plants", json=payload, headers=headers)


def test_requires_login(client):
    assert client.get("/api/plants").status_code == 401


def test_create_lands_in_personal_workspace(client, make_user, as_user):
    fern = make_user("fern")
    resp = _create(client, as_user(fern), name="Pothos", species="Epipremnum aureum")
    assert resp.status_code == 201
    plant = session.get(Plant, resp.get_json()["id"])
    assert plant.workspace.is_personal
    assert plant.workspace.created_by_id == fern.id


def test_create_requires_name(client, make_user, as_user):
    fern = make_user("fern")
    resp = _create(client, as_user(fern), name="   ")
    assert resp.status_code == 400
    assert session.query(Plant).count() == 0


def test_create_in_shared_workspace_needs_editor(client, make_user, make_workspace, as_user):
    fern, ivy = make_user("fern"), make_user("ivy")
    balcony = make_workspace(fern, "Balcony", members=[(ivy, "viewer")])
    resp = _create(client, as_user(ivy), name="Basil", workspace=balcony.slug)
    assert resp.status_code == 403


def test_list_includes_shared_workspace_plants(client, make_user, make_workspace, as_user):
    fern, ivy = make_user("fern"), make_user("ivy")
    balcony = make_workspace(fern, "Balcony", members=[(ivy, "viewer")])
    _create(client, as_user(fern), name="Basil", workspace=balcony.slug)
    names = [p["name"] for p in client.get("/api/plants", headers=as_user(ivy)).get_json()]
    assert names == ["Basil"]


def test_list_hides_workspaces_you_are_not_in(client, make_user, make_workspace, as_user):
    fern, ivy = make_user("fern"), make_user("ivy")
    balcony = make_workspace(fern, "Balcony")
    _create(client, as_user(fern), name="Basil", workspace=balcony.slug)
    assert client.get("/api/plants", headers=as_user(ivy)).get_json() == []


def test_list_filtered_by_workspace(client, make_user, make_workspace, as_user):
    fern = make_user("fern")
    balcony = make_workspace(fern, "Balcony")
    _create(client, as_user(fern), name="Calathea")
    _create(client, as_user(fern), name="Basil", workspace=balcony.slug)
    resp = client.get(f"/api/plants?workspace={balcony.slug}", headers=as_user(fern))
    assert [p["name"] for p in resp.get_json()] == ["Basil"]


def test_viewer_cannot_update(client, make_user, make_workspace, as_user):
    fern, ivy = make_user("fern"), make_user("ivy")
    balcony = make_workspace(fern, "Balcony", members=[(ivy, "viewer")])
    plant_id = _create(client, as_user(fern), workspace=balcony.slug).get_json()["id"]
    resp = client.patch(f"/api/plants/{plant_id}", json={"name": "Mine"}, headers=as_user(ivy))
    assert resp.status_code == 403


def test_editor_can_update(client, make_user, make_workspace, as_user):
    fern, ivy = make_user("fern"), make_user("ivy")
    balcony = make_workspace(fern, "Balcony", members=[(ivy, "editor")])
    plant_id = _create(client, as_user(fern), workspace=balcony.slug).get_json()["id"]
    resp = client.patch(
        f"/api/plants/{plant_id}",
        json={"location": "Railing planter", "watering_interval_days": 2},
        headers=as_user(ivy),
    )
    assert resp.status_code == 200
    assert resp.get_json()["location"] == "Railing planter"


def test_non_member_gets_404(client, make_user, as_user):
    fern, ivy = make_user("fern"), make_user("ivy")
    plant_id = _create(client, as_user(fern)).get_json()["id"]
    resp = client.patch(f"/api/plants/{plant_id}", json={"name": "Mine"}, headers=as_user(ivy))
    assert resp.status_code == 404


def test_update_rejects_bad_interval(client, make_user, as_user):
    fern = make_user("fern")
    plant_id = _create(client, as_user(fern)).get_json()["id"]
    resp = client.patch(
        f"/api/plants/{plant_id}", json={"watering_interval_days": 0}, headers=as_user(fern)
    )
    assert resp.status_code == 400


def test_move_plant_records_audit_entry(client, make_user, make_workspace, as_user):
    fern = make_user("fern")
    balcony = make_workspace(fern, "Balcony")
    plant_id = _create(client, as_user(fern)).get_json()["id"]
    resp = client.post(
        f"/api/plants/{plant_id}/move", json={"workspace": balcony.slug}, headers=as_user(fern)
    )
    assert resp.status_code == 200
    assert resp.get_json()["workspace_id"] == balcony.id
    entry = session.query(AuditEntry).filter_by(kind=PlantMoved.kind).one()
    assert entry.subject_id == plant_id
    assert entry.details["workspace_id"] == balcony.id


def test_move_requires_editor_in_target(client, make_user, make_workspace, as_user):
    fern, ivy = make_user("fern"), make_user("ivy")
    greenhouse = make_workspace(fern, "Greenhouse", members=[(ivy, "viewer")])
    plant_id = _create(client, as_user(ivy)).get_json()["id"]
    resp = client.post(
        f"/api/plants/{plant_id}/move", json={"workspace": greenhouse.slug}, headers=as_user(ivy)
    )
    assert resp.status_code == 403
EOF

cat > tests/test_permissions.py <<'EOF'
import pytest

from sprout.models.plant import Plant
from sprout.models.user import User
from sprout.permissions import PERMISSIONS, Actor, actor_for, can


def test_legacy_plant_without_workspace_falls_back_to_owner():
    fern = Actor(User(id=1, username="fern"))
    assert can(fern, "plant:update", Plant(owner_id=1, name="Fig", workspace_id=None))


def test_legacy_plant_non_owner_denied():
    ivy = Actor(User(id=2, username="ivy"))
    assert not can(ivy, "plant:update", Plant(owner_id=1, name="Fig", workspace_id=None))


def test_workspace_roles(make_user, make_workspace):
    fern, ivy, moss = make_user("fern"), make_user("ivy"), make_user("moss")
    balcony = make_workspace(fern, "Balcony", members=[(ivy, "viewer"), (moss, "editor")])
    plant = Plant(owner_id=fern.id, workspace_id=balcony.id, name="Basil")
    assert can(Actor(ivy), "plant:read", plant)
    assert not can(Actor(ivy), "plant:update", plant)
    assert can(Actor(moss), "plant:update", plant)
    assert not can(actor_for(moss, balcony), "workspace:manage_members", balcony)
    assert can(actor_for(fern, balcony), "workspace:manage_members", balcony)


def test_bare_user_is_rejected():
    with pytest.raises(TypeError):
        can(User(id=1, username="fern"), "plant:read", Plant(owner_id=1, name="Fig"))


def test_anonymous_can_do_nothing():
    assert not can(None, "plant:read", Plant(owner_id=1, name="Fig"))


def test_unknown_action_is_a_bug():
    with pytest.raises(KeyError):
        can(Actor(User(id=1, username="fern")), "plant:teleport", None)


def test_every_action_is_namespaced():
    assert all(":" in action for action in PERMISSIONS)
EOF

cat > sprout/carelog/api.py <<'EOF'
"""JSON API for the care log.

Each entry records one thing someone did for a plant. Logging a watering also
updates the plant's ``last_watered_at`` so thirst tracking stays accurate.
"""
from __future__ import annotations

from flask import Blueprint, abort, g, jsonify, request
from sqlalchemy import select

from sprout.auth import login_required
from sprout.config import CARELOG_PAGE_SIZE
from sprout.db import session, utcnow
from sprout.models.care_event import CARE_ACTIONS, CareEvent
from sprout.models.plant import Plant
from sprout.permissions import actor_for, can

bp = Blueprint("carelog", __name__, url_prefix="/api/care-log")


@bp.get("")
@login_required
def list_entries():
    """The current user's most recent care-log entries, newest first."""
    stmt = (
        select(CareEvent)
        .where(CareEvent.user_id == g.user.id)
        .order_by(CareEvent.occurred_at.desc(), CareEvent.id.desc())
        .limit(CARELOG_PAGE_SIZE)
    )
    return jsonify([entry.to_dict() for entry in session.scalars(stmt)])


@bp.post("/<int:plant_id>")
@login_required
def log_care(plant_id: int):
    plant = session.get(Plant, plant_id)
    actor = actor_for(g.user)
    if plant is None or not can(actor, "plant:read", plant):
        abort(404)
    if not can(actor, "plant:water", plant):
        abort(403)
    payload = request.get_json(silent=True) or {}
    action = payload.get("action", "watered")
    if action not in CARE_ACTIONS:
        return jsonify(error=f"action must be one of {', '.join(CARE_ACTIONS)}"), 400
    entry = CareEvent(
        plant_id=plant.id,
        user_id=g.user.id,
        action=action,
        note=(payload.get("note") or "").strip(),
        occurred_at=utcnow(),
    )
    if action == "watered":
        plant.last_watered_at = entry.occurred_at
    session.add(entry)
    session.commit()
    return jsonify(entry.to_dict()), 201
EOF

cat > tests/carelog/test_carelog_api.py <<'EOF'
from sprout.db import session
from sprout.models.plant import Plant
from sprout.models.user import User
from sprout.permissions import Actor, can


def _plant(client, user, as_user, name="Fiddle leaf fig"):
    resp = client.post("/api/plants", json={"name": name}, headers=as_user(user))
    return resp.get_json()["id"]


def test_logging_a_watering_updates_the_plant(client, make_user, as_user):
    fern = make_user("fern")
    plant_id = _plant(client, fern, as_user)
    resp = client.post(f"/api/care-log/{plant_id}", json={"note": "soaked"}, headers=as_user(fern))
    assert resp.status_code == 201
    assert session.get(Plant, plant_id).last_watered_at is not None


def test_rejects_unknown_action(client, make_user, as_user):
    fern = make_user("fern")
    plant_id = _plant(client, fern, as_user)
    resp = client.post(
        f"/api/care-log/{plant_id}", json={"action": "serenaded"}, headers=as_user(fern)
    )
    assert resp.status_code == 400


def test_cannot_log_for_someone_elses_plant(client, make_user, as_user):
    fern, ivy = make_user("fern"), make_user("ivy")
    plant_id = _plant(client, fern, as_user)
    assert client.post(f"/api/care-log/{plant_id}", json={}, headers=as_user(ivy)).status_code == 404


def test_list_is_newest_first(client, make_user, as_user):
    fern = make_user("fern")
    plant_id = _plant(client, fern, as_user)
    for action in ("watered", "fed"):
        client.post(f"/api/care-log/{plant_id}", json={"action": action}, headers=as_user(fern))
    listed = client.get("/api/care-log", headers=as_user(fern)).get_json()
    assert [entry["action"] for entry in listed] == ["fed", "watered"]


def test_legacy_plant_water_falls_back_to_owner():
    fern, ivy = User(id=1, username="fern"), User(id=2, username="ivy")
    plant = Plant(owner_id=1, name="Fig", workspace_id=None)
    assert can(Actor(fern), "plant:water", plant)
    assert not can(Actor(ivy), "plant:water", plant)


def test_watering_needs_editor_role(make_user, make_workspace):
    fern, ivy, moss = make_user("fern"), make_user("ivy"), make_user("moss")
    balcony = make_workspace(fern, "Balcony", members=[(ivy, "viewer"), (moss, "editor")])
    plant = Plant(owner_id=fern.id, workspace_id=balcony.id, name="Basil")
    assert can(Actor(moss), "plant:water", plant)
    assert not can(Actor(ivy), "plant:water", plant)


def test_viewer_gets_403(client, make_user, make_workspace, as_user):
    fern, ivy = make_user("fern"), make_user("ivy")
    balcony = make_workspace(fern, "Balcony", members=[(ivy, "viewer")])
    resp = client.post(
        "/api/plants", json={"name": "Basil", "workspace": balcony.slug}, headers=as_user(fern)
    )
    plant_id = resp.get_json()["id"]
    assert client.post(f"/api/care-log/{plant_id}", json={}, headers=as_user(ivy)).status_code == 403
EOF

commit_at "2026-02-16T09:30:00+00:00" -m "Scope plants to workspaces (migration 0006, membership-based access)"

# --- F5: invite links ------------------------------------------------------
cat > pyproject.toml <<'EOF'
[build-system]
requires = ["setuptools>=68"]
build-backend = "setuptools.build_meta"

[project]
name = "sprout"
version = "2.4.0.dev0"
description = "Plant-care tracking for people who forget to water things."
readme = "README.md"
requires-python = ">=3.11"
dependencies = [
    "flask>=3.0",
    "itsdangerous>=2.1",
    "python-slugify>=8.0",
    "sqlalchemy>=2.0",
]

[project.optional-dependencies]
dev = [
    "pytest>=8.0",
]

[tool.setuptools.packages.find]
include = ["sprout*"]

[tool.pytest.ini_options]
testpaths = ["tests"]
addopts = "-ra --strict-markers"
filterwarnings = ["error::DeprecationWarning:sprout.*"]
EOF

cat > sprout/models/invite.py <<'EOF'
"""A shareable invitation to join a workspace."""
from __future__ import annotations

from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Integer, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from sprout.db import Base, ensure_aware, utcnow


class Invite(Base):
    """Source of truth for an invite link.

    The link itself only carries a signed reference to :attr:`nonce`; role,
    remaining uses, expiry and revocation all live here.
    """

    __tablename__ = "invites"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    workspace_id: Mapped[int] = mapped_column(
        ForeignKey("workspaces.id", ondelete="CASCADE"), nullable=False, index=True
    )
    created_by_id: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False)
    role: Mapped[str] = mapped_column(String(16), nullable=False, default="viewer")
    nonce: Mapped[str] = mapped_column(String(43), nullable=False, unique=True)
    max_uses: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    use_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    revoked_by_id: Mapped[int | None] = mapped_column(ForeignKey("users.id"), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utcnow
    )

    workspace = relationship("Workspace")
    created_by = relationship("User", foreign_keys=[created_by_id])
    revoked_by = relationship("User", foreign_keys=[revoked_by_id])

    @property
    def uses_left(self) -> int:
        return max(self.max_uses - self.use_count, 0)

    def is_usable(self, now: datetime | None = None) -> bool:
        now = now or utcnow()
        return (
            self.revoked_at is None
            and self.uses_left > 0
            and ensure_aware(self.expires_at) > now
        )

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "workspace_id": self.workspace_id,
            "role": self.role,
            "max_uses": self.max_uses,
            "uses_left": self.uses_left,
            "expires_at": self.expires_at.isoformat(),
            "revoked": self.revoked_at is not None,
        }

    def __repr__(self) -> str:
        return f"<Invite {self.id} ws={self.workspace_id} {self.role}>"
EOF

cat > sprout/models/__init__.py <<'EOF'
"""All Sprout models, imported here so ``Base.metadata`` sees every table."""
from sprout.models.audit_entry import AuditEntry
from sprout.models.care_event import CareEvent
from sprout.models.invite import Invite
from sprout.models.membership import Membership
from sprout.models.plant import Plant
from sprout.models.user import User
from sprout.models.workspace import Workspace

__all__ = ["AuditEntry", "CareEvent", "Invite", "Membership", "Plant", "User", "Workspace"]
EOF

cat > migrations/0007_invites.py <<'EOF'
"""Create the invites table for shareable workspace invite links.

Revision: 0007
Revises: 0006
"""
from sqlalchemy import text

revision = "0007"
down_revision = "0006"


def upgrade(conn) -> None:
    conn.execute(
        text(
            """
            CREATE TABLE invites (
                id INTEGER PRIMARY KEY,
                workspace_id INTEGER NOT NULL REFERENCES workspaces (id) ON DELETE CASCADE,
                created_by_id INTEGER NOT NULL REFERENCES users (id),
                role VARCHAR(16) NOT NULL DEFAULT 'viewer',
                nonce VARCHAR(43) NOT NULL UNIQUE,
                max_uses INTEGER NOT NULL DEFAULT 1,
                use_count INTEGER NOT NULL DEFAULT 0,
                expires_at TIMESTAMP NOT NULL,
                revoked_at TIMESTAMP,
                revoked_by_id INTEGER REFERENCES users (id),
                created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                CONSTRAINT ck_invites_role CHECK (role IN ('viewer', 'editor'))
            )
            """
        )
    )
    conn.execute(text("CREATE INDEX ix_invites_workspace_id ON invites (workspace_id)"))


def downgrade(conn) -> None:
    conn.execute(text("DROP INDEX ix_invites_workspace_id"))
    conn.execute(text("DROP TABLE invites"))
EOF

cat > sprout/workspaces/invites.py <<'EOF'
"""Signed, shareable invite links for workspaces.

An invite link carries a token signed with the app's ``SECRET_KEY``. The token
only names an :class:`~sprout.models.invite.Invite` row by its nonce; the row
is the source of truth for role, remaining uses and revocation, so a leaked
link can be killed without rotating the key.
"""
from __future__ import annotations

import secrets
from datetime import timedelta

from flask import current_app
from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer
from sqlalchemy import select

from sprout.db import session, utcnow
from sprout.models.invite import Invite
from sprout.models.membership import ROLES, Membership
from sprout.models.user import User
from sprout.models.workspace import Workspace
from sprout.workspaces import service

TOKEN_SALT = "sprout.workspace-invite.v1"
DEFAULT_MAX_AGE = timedelta(days=7)
MAX_USES_LIMIT = 50


class InviteError(Exception):
    """Base class for every reason an invite cannot be created or used."""


class InvalidInvite(InviteError):
    pass


class ExpiredInvite(InviteError):
    pass


class RevokedInvite(InviteError):
    pass


class InviteUsedUp(InviteError):
    pass


def _serializer() -> URLSafeTimedSerializer:
    return URLSafeTimedSerializer(current_app.config["SECRET_KEY"], salt=TOKEN_SALT)


def _max_age() -> timedelta:
    return current_app.config.get("INVITE_MAX_AGE", DEFAULT_MAX_AGE)


def create_invite(
    workspace: Workspace, inviter: User, *, role: str = "viewer", max_uses: int = 1
) -> tuple[Invite, str]:
    """Create an invite row and return it with its signed token."""
    if role not in ROLES or role == "owner":
        raise InvalidInvite(f"invites cannot grant the {role!r} role")
    if not 1 <= max_uses <= MAX_USES_LIMIT:
        raise InvalidInvite(f"max_uses must be between 1 and {MAX_USES_LIMIT}")
    invite = Invite(
        workspace_id=workspace.id,
        created_by_id=inviter.id,
        role=role,
        nonce=secrets.token_urlsafe(24),
        max_uses=max_uses,
        expires_at=utcnow() + _max_age(),
    )
    session.add(invite)
    session.commit()
    return invite, sign_invite(invite)


def sign_invite(invite: Invite) -> str:
    """The signed link token for an existing invite row."""
    return _serializer().dumps({"n": invite.nonce, "w": invite.workspace_id})


def load_invite(token: str) -> Invite:
    """Verify ``token`` and return its live invite, or raise :class:`InviteError`."""
    try:
        data = _serializer().loads(token, max_age=int(_max_age().total_seconds()))
    except SignatureExpired as exc:
        raise ExpiredInvite("this invite link has expired") from exc
    except BadSignature as exc:
        raise InvalidInvite("this invite link is not valid") from exc
    invite = session.scalar(select(Invite).where(Invite.nonce == data.get("n")))
    if invite is None or invite.workspace_id != data.get("w"):
        raise InvalidInvite("this invite link is not valid")
    if invite.revoked_at is not None:
        raise RevokedInvite("this invite was revoked")
    if invite.uses_left == 0:
        raise InviteUsedUp("this invite has already been used")
    return invite


def accept_invite(token: str, user: User) -> Membership:
    """Join the invite's workspace. Accepting twice is harmless."""
    invite = load_invite(token)
    existing = service.membership_for(invite.workspace, user)
    if existing is not None:
        return existing
    membership = service.add_member(
        invite.workspace, invite.created_by, user, role=invite.role, commit=False
    )
    invite.use_count += 1
    session.commit()
    return membership


def revoke_invite(invite: Invite, actor: User) -> None:
    invite.revoked_at = utcnow()
    invite.revoked_by_id = actor.id
    session.commit()
EOF

cat > sprout/workspaces/api.py <<'EOF'
"""HTTP routes for workspaces and their members.

JSON in, JSON out. Rule violations raised by :mod:`sprout.workspaces.service`
become ``409`` responses via :func:`_workspace_error`. Workspaces the current
user does not belong to always look like ``404``, never ``403``.
"""
from __future__ import annotations

from flask import Blueprint, abort, g, jsonify, redirect, render_template, request, url_for
from sqlalchemy import select

from sprout.auth import login_required
from sprout.db import session
from sprout.models.invite import Invite
from sprout.models.user import User
from sprout.permissions import actor_for, can
from sprout.workspaces import invites, service

bp = Blueprint("workspaces", __name__, url_prefix="/workspaces")


def _workspace_or_404(slug: str):
    """Load a workspace the current user belongs to, or abort with 404."""
    workspace = service.get_by_slug(slug)
    if workspace is None or service.membership_for(workspace, g.user) is None:
        abort(404)
    return workspace


def _require_role(workspace, minimum: str):
    """The current user's membership, if their role is at least ``minimum``."""
    membership = service.membership_for(workspace, g.user)
    if membership is None:
        abort(404)
    if not membership.has_role(minimum):
        abort(403)
    return membership


def _user_or_404(user_id: int) -> User:
    user = session.get(User, user_id)
    if user is None:
        abort(404)
    return user


@bp.errorhandler(service.WorkspaceError)
def _workspace_error(exc: service.WorkspaceError):
    return jsonify(error=str(exc), code=type(exc).__name__), 409


@bp.get("")
@login_required
def list_workspaces():
    return jsonify([workspace.to_dict() for workspace in service.workspaces_for(g.user)])


@bp.post("")
@login_required
def create_workspace():
    payload = request.get_json(silent=True) or {}
    workspace = service.create_workspace(g.user, payload.get("name", ""))
    return jsonify(workspace.to_dict()), 201


@bp.get("/<slug>")
@login_required
def show_workspace(slug: str):
    workspace = _workspace_or_404(slug)
    data = workspace.to_dict()
    data["members"] = [membership.to_dict() for membership in workspace.memberships]
    return jsonify(data)


@bp.post("/<slug>/members")
@login_required
def add_member(slug: str):
    workspace = _workspace_or_404(slug)
    _require_role(workspace, "owner")
    payload = request.get_json(silent=True) or {}
    username = (payload.get("username") or "").strip()
    user = session.scalar(select(User).where(User.username == username))
    if user is None:
        return jsonify(error=f"no user named {username!r}"), 404
    membership = service.add_member(workspace, g.user, user, role=payload.get("role", "viewer"))
    return jsonify(membership.to_dict()), 201


@bp.delete("/<slug>/members/<int:user_id>")
@login_required
def remove_member(slug: str, user_id: int):
    workspace = _workspace_or_404(slug)
    target = _user_or_404(user_id)
    if target.id != g.user.id:
        # Anyone may leave; only owners may remove other people.
        _require_role(workspace, "owner")
    service.remove_member(workspace, g.user, target)
    return "", 204


# --- Invite links ------------------------------------------------------------


@bp.post("/<slug>/invites")
@login_required
def create_invite(slug: str):
    workspace = _workspace_or_404(slug)
    if not can(actor_for(g.user, workspace), "invite:create", workspace):
        abort(403)
    payload = request.get_json(silent=True) or {}
    try:
        invite, token = invites.create_invite(
            workspace,
            g.user,
            role=payload.get("role", "viewer"),
            max_uses=int(payload.get("max_uses", 1)),
        )
    except (invites.InviteError, ValueError) as exc:
        return jsonify(error=str(exc)), 400
    data = invite.to_dict()
    data["url"] = url_for("workspaces.show_invite", token=token, _external=True)
    return jsonify(data), 201


@bp.delete("/<slug>/invites/<int:invite_id>")
@login_required
def revoke_invite(slug: str, invite_id: int):
    workspace = _workspace_or_404(slug)
    if not can(actor_for(g.user, workspace), "invite:revoke", workspace):
        abort(403)
    invite = session.get(Invite, invite_id)
    if invite is None or invite.workspace_id != workspace.id:
        abort(404)
    invites.revoke_invite(invite, g.user)
    return "", 204


@bp.get("/invites/<token>")
@login_required
def show_invite(token: str):
    try:
        invite = invites.load_invite(token)
    except invites.InviteError as exc:
        return render_template("invite_accept.html", invite=None, token=token, error=str(exc)), 410
    already_member = not can(actor_for(g.user), "invite:accept", invite)
    return render_template(
        "invite_accept.html",
        invite=invite,
        token=token,
        error=None,
        already_member=already_member,
    )


@bp.post("/invites/<token>/accept")
@login_required
def accept_invite(token: str):
    try:
        membership = invites.accept_invite(token, g.user)
    except invites.InviteError as exc:
        return render_template("invite_accept.html", invite=None, token=token, error=str(exc)), 410
    return redirect(url_for("workspaces.show_workspace", slug=membership.workspace.slug))
EOF

cat > sprout/templates/invite_accept.html <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Join a workspace &middot; Sprout</title>
</head>
<body>
  {% include "nav.html" %}
  <main class="invite">
    {% if error %}
      <h1>This invite can't be used</h1>
      <p class="invite__error">{{ error }}</p>
      <p>Ask whoever sent it for a fresh link.</p>
      <p><a href="{{ url_for('workspaces.list_workspaces') }}">Back to your workspaces</a></p>
    {% elif already_member %}
      <h1>You're already in {{ invite.workspace.name }}</h1>
      <p>
        <a href="{{ url_for('workspaces.show_workspace', slug=invite.workspace.slug) }}">
          Go to {{ invite.workspace.name }}
        </a>
      </p>
    {% else %}
      <h1>Join {{ invite.workspace.name }}</h1>
      <p>
        {{ invite.created_by.display_name or invite.created_by.username }} invited you
        to help look after the plants in <strong>{{ invite.workspace.name }}</strong>
        as {{ "an" if invite.role == "editor" else "a" }} <strong>{{ invite.role }}</strong>.
      </p>
      <ul class="invite__facts">
        <li>{{ invite.workspace.memberships|length }} people are already members.</li>
        <li>This link works until {{ invite.expires_at.strftime("%B %d, %Y") }}.</li>
      </ul>
      <form method="post" action="{{ url_for('workspaces.accept_invite', token=token) }}">
        <button type="submit" class="button button--primary">Accept and join</button>
        <a class="button" href="/">No thanks</a>
      </form>
    {% endif %}
  </main>
</body>
</html>
EOF

commit_at "2026-02-18T13:10:00+00:00" -m "Invite links: signed tokens, invites table, accept page"

# --- F6: nav entry points + workspace switcher ------------------------------
cat > sprout/templates/nav.html <<'EOF'
{# Primary navigation, included from every page layout. #}
{% set user = g.get("user") %}
{% set memberships = user.memberships if user else [] %}
{% set current_ws = (memberships|first).workspace if memberships else none %}
<nav class="sprout-nav" aria-label="Primary">
  <a class="sprout-nav__brand" href="/">Sprout</a>
  <ul class="sprout-nav__links">
    <li><a href="/plants">My plants</a></li>
    <li><a href="/care-log">Care log</a></li>
    {% if user %}
    <li><a href="{{ url_for('workspaces.list_workspaces') }}">Workspaces</a></li>
    {% if current_ws %}
    <li><a href="{{ url_for('workspaces.activity_page', slug=current_ws.slug) }}">Activity</a></li>
    {% endif %}
    {% endif %}
  </ul>
  {% if user %}
  {% include "_workspace_switcher.html" %}
  {% endif %}
</nav>
EOF

cat > sprout/templates/_workspace_switcher.html <<'EOF'
{#
  Workspace switcher, included from nav.html.
  Expects `memberships` (the signed-in user's memberships) and `current_ws`.
#}
<div class="workspace-switcher">
  <label class="workspace-switcher__label" for="workspace-switcher-select">Workspace</label>
  <select id="workspace-switcher-select"
          class="workspace-switcher__select"
          onchange="if (this.value) { window.location = this.value; }">
    {% for membership in memberships %}
      {% set ws = membership.workspace %}
      <option value="{{ url_for('workspaces.show_workspace', slug=ws.slug) }}"
              {% if current_ws and ws.id == current_ws.id %}selected{% endif %}>
        {{ ws.name }}{% if ws.is_personal %} (personal){% endif %} &middot; {{ membership.role }}
      </option>
    {% endfor %}
  </select>
  <a class="workspace-switcher__new" href="{{ url_for('workspaces.list_workspaces') }}#new">
    New workspace
  </a>
</div>
EOF

commit_at "2026-02-19T17:25:00+00:00" -m "Nav: Workspaces + Activity links, workspace switcher"

# --- F7: member activity page ----------------------------------------------
cat > sprout/workspaces/activity.py <<'EOF'
"""Member activity for a workspace.

Built on the generic audit log: for each current member we pull their recent
audit entries with :func:`sprout.audit.recent`, keep the ones that concern
this workspace, and merge them newest-first into a single timeline.

People who have left the workspace drop out of the timeline; that is on
purpose, the page answers "what have my housemates been doing?".
"""
from __future__ import annotations

import heapq
from dataclasses import dataclass
from datetime import datetime

from sprout.audit import MemberAdded, MemberRemoved, PlantMoved, recent
from sprout.models.audit_entry import AuditEntry
from sprout.models.workspace import Workspace

DEFAULT_LIMIT = 50
PER_MEMBER_LIMIT = 100


@dataclass(frozen=True)
class ActivityItem:
    occurred_at: datetime
    actor_id: int | None
    actor_name: str
    kind: str
    summary: str


def _concerns(entry: AuditEntry, workspace: Workspace) -> bool:
    """True if ``entry`` is about ``workspace`` or something inside it."""
    if entry.subject_type == "workspace" and entry.subject_id == workspace.id:
        return True
    details = entry.details
    return workspace.id in (details.get("workspace_id"), details.get("from_workspace_id"))


def _summarize(entry: AuditEntry, names: dict[int, str]) -> str:
    details = entry.details
    member = names.get(details.get("member_id"), "a former member")
    if entry.kind == MemberAdded.kind:
        if details.get("member_id") == entry.actor_id:
            return f"joined as {details.get('role', 'member')}"
        return f"added {member} as {details.get('role', 'member')}"
    if entry.kind == MemberRemoved.kind:
        if details.get("member_id") == entry.actor_id:
            return "left the workspace"
        return f"removed {member}"
    if entry.kind == PlantMoved.kind:
        return f"moved plant #{details.get('plant_id')} into {details.get('workspace_slug')}"
    return entry.kind.replace(".", ": ").replace("_", " ")


def member_activity(workspace: Workspace, limit: int = DEFAULT_LIMIT) -> list[ActivityItem]:
    """Newest-first activity by the workspace's current members."""
    names = {
        membership.user_id: membership.user.display_name or membership.user.username
        for membership in workspace.memberships
    }
    streams = [
        [entry for entry in recent(user_id, PER_MEMBER_LIMIT) if _concerns(entry, workspace)]
        for user_id in names
    ]
    merged = heapq.merge(
        *streams, key=lambda entry: (entry.occurred_at, entry.id), reverse=True
    )
    items: list[ActivityItem] = []
    for entry in merged:
        items.append(
            ActivityItem(
                occurred_at=entry.occurred_at,
                actor_id=entry.actor_id,
                actor_name=names.get(entry.actor_id, "someone"),
                kind=entry.kind,
                summary=_summarize(entry, names),
            )
        )
        if len(items) >= limit:
            break
    return items
EOF

cat > sprout/workspaces/api.py <<'EOF'
"""HTTP routes for workspaces and their members.

JSON in, JSON out. Rule violations raised by :mod:`sprout.workspaces.service`
become ``409`` responses via :func:`_workspace_error`. Workspaces the current
user does not belong to always look like ``404``, never ``403``.
"""
from __future__ import annotations

from flask import Blueprint, abort, g, jsonify, redirect, render_template, request, url_for
from sqlalchemy import select

from sprout.auth import login_required
from sprout.db import session
from sprout.models.invite import Invite
from sprout.models.user import User
from sprout.permissions import actor_for, can
from sprout.workspaces import invites, service
from sprout.workspaces.activity import DEFAULT_LIMIT, member_activity

bp = Blueprint("workspaces", __name__, url_prefix="/workspaces")


def _workspace_or_404(slug: str):
    """Load a workspace the current user belongs to, or abort with 404."""
    workspace = service.get_by_slug(slug)
    if workspace is None or service.membership_for(workspace, g.user) is None:
        abort(404)
    return workspace


def _require_role(workspace, minimum: str):
    """The current user's membership, if their role is at least ``minimum``."""
    membership = service.membership_for(workspace, g.user)
    if membership is None:
        abort(404)
    if not membership.has_role(minimum):
        abort(403)
    return membership


def _user_or_404(user_id: int) -> User:
    user = session.get(User, user_id)
    if user is None:
        abort(404)
    return user


@bp.errorhandler(service.WorkspaceError)
def _workspace_error(exc: service.WorkspaceError):
    return jsonify(error=str(exc), code=type(exc).__name__), 409


@bp.get("")
@login_required
def list_workspaces():
    return jsonify([workspace.to_dict() for workspace in service.workspaces_for(g.user)])


@bp.post("")
@login_required
def create_workspace():
    payload = request.get_json(silent=True) or {}
    workspace = service.create_workspace(g.user, payload.get("name", ""))
    return jsonify(workspace.to_dict()), 201


@bp.get("/<slug>")
@login_required
def show_workspace(slug: str):
    workspace = _workspace_or_404(slug)
    data = workspace.to_dict()
    data["members"] = [membership.to_dict() for membership in workspace.memberships]
    return jsonify(data)


@bp.post("/<slug>/members")
@login_required
def add_member(slug: str):
    workspace = _workspace_or_404(slug)
    _require_role(workspace, "owner")
    payload = request.get_json(silent=True) or {}
    username = (payload.get("username") or "").strip()
    user = session.scalar(select(User).where(User.username == username))
    if user is None:
        return jsonify(error=f"no user named {username!r}"), 404
    membership = service.add_member(workspace, g.user, user, role=payload.get("role", "viewer"))
    return jsonify(membership.to_dict()), 201


@bp.delete("/<slug>/members/<int:user_id>")
@login_required
def remove_member(slug: str, user_id: int):
    workspace = _workspace_or_404(slug)
    target = _user_or_404(user_id)
    if target.id != g.user.id:
        # Anyone may leave; only owners may remove other people.
        _require_role(workspace, "owner")
    service.remove_member(workspace, g.user, target)
    return "", 204


# --- Member activity ---------------------------------------------------------


@bp.get("/<slug>/activity")
@login_required
def activity_page(slug: str):
    workspace = _workspace_or_404(slug)
    limit = request.args.get("limit", default=DEFAULT_LIMIT, type=int)
    items = member_activity(workspace, limit=max(1, min(limit, 200)))
    return render_template("workspace_activity.html", workspace=workspace, items=items)


# --- Invite links ------------------------------------------------------------


@bp.post("/<slug>/invites")
@login_required
def create_invite(slug: str):
    workspace = _workspace_or_404(slug)
    if not can(actor_for(g.user, workspace), "invite:create", workspace):
        abort(403)
    payload = request.get_json(silent=True) or {}
    try:
        invite, token = invites.create_invite(
            workspace,
            g.user,
            role=payload.get("role", "viewer"),
            max_uses=int(payload.get("max_uses", 1)),
        )
    except (invites.InviteError, ValueError) as exc:
        return jsonify(error=str(exc)), 400
    data = invite.to_dict()
    data["url"] = url_for("workspaces.show_invite", token=token, _external=True)
    return jsonify(data), 201


@bp.delete("/<slug>/invites/<int:invite_id>")
@login_required
def revoke_invite(slug: str, invite_id: int):
    workspace = _workspace_or_404(slug)
    if not can(actor_for(g.user, workspace), "invite:revoke", workspace):
        abort(403)
    invite = session.get(Invite, invite_id)
    if invite is None or invite.workspace_id != workspace.id:
        abort(404)
    invites.revoke_invite(invite, g.user)
    return "", 204


@bp.get("/invites/<token>")
@login_required
def show_invite(token: str):
    try:
        invite = invites.load_invite(token)
    except invites.InviteError as exc:
        return render_template("invite_accept.html", invite=None, token=token, error=str(exc)), 410
    already_member = not can(actor_for(g.user), "invite:accept", invite)
    return render_template(
        "invite_accept.html",
        invite=invite,
        token=token,
        error=None,
        already_member=already_member,
    )


@bp.post("/invites/<token>/accept")
@login_required
def accept_invite(token: str):
    try:
        membership = invites.accept_invite(token, g.user)
    except invites.InviteError as exc:
        return render_template("invite_accept.html", invite=None, token=token, error=str(exc)), 410
    return redirect(url_for("workspaces.show_workspace", slug=membership.workspace.slug))
EOF

cat > sprout/templates/workspace_activity.html <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>{{ workspace.name }} activity &middot; Sprout</title>
</head>
<body>
  {% include "nav.html" %}
  <main class="activity">
    <header class="activity__header">
      <h1>Recent activity in {{ workspace.name }}</h1>
      <p class="activity__meta">
        {{ workspace.memberships|length }} {{ "member" if workspace.memberships|length == 1 else "members" }}
        &middot; showing the latest {{ items|length }} {{ "entry" if items|length == 1 else "entries" }}
      </p>
    </header>

    {% if items %}
      <ol class="activity__list">
        {% for item in items %}
          <li class="activity__item activity__item--{{ item.kind|replace('.', '-')|replace('_', '-') }}">
            <time class="activity__when" datetime="{{ item.occurred_at.isoformat() }}">
              {{ item.occurred_at.strftime("%b %d, %H:%M") }}
            </time>
            <span class="activity__actor">{{ item.actor_name }}</span>
            <span class="activity__summary">{{ item.summary }}</span>
          </li>
        {% endfor %}
      </ol>
    {% else %}
      <p class="activity__empty">Nothing has happened here yet. Invite someone to get started.</p>
    {% endif %}
  </main>
</body>
</html>
EOF

mkdir -p tests/workspaces
cat > tests/workspaces/test_activity.py <<'EOF'
from sprout.workspaces.activity import member_activity


def test_activity_lists_membership_changes_newest_first(make_user, make_workspace):
    fern, ivy = make_user("fern"), make_user("ivy")
    balcony = make_workspace(fern, "Balcony", members=[(ivy, "editor")])
    items = member_activity(balcony)
    assert [item.summary for item in items] == ["added Ivy as editor", "joined as owner"]
    assert items[0].actor_name == "Fern"


def test_activity_ignores_other_workspaces(make_user, make_workspace):
    fern, ivy = make_user("fern"), make_user("ivy")
    balcony = make_workspace(fern, "Balcony")
    make_workspace(fern, "Greenhouse", members=[(ivy, "viewer")])
    summaries = [item.summary for item in member_activity(balcony)]
    assert summaries == ["joined as owner"]


def test_activity_page_renders_for_members(client, make_user, make_workspace, as_user):
    fern = make_user("fern")
    balcony = make_workspace(fern, "Balcony")
    resp = client.get(f"/workspaces/{balcony.slug}/activity", headers=as_user(fern))
    assert resp.status_code == 200
    assert b"Recent activity in Balcony" in resp.data


def test_activity_page_hidden_from_non_members(client, make_user, make_workspace, as_user):
    fern, ivy = make_user("fern"), make_user("ivy")
    balcony = make_workspace(fern, "Balcony")
    resp = client.get(f"/workspaces/{balcony.slug}/activity", headers=as_user(ivy))
    assert resp.status_code == 404
EOF

commit_at "2026-02-23T10:50:00+00:00" -m "Member activity page built on audit recent()"

# --- F8: tests for audit log, workspaces, invites --------------------------
mkdir -p tests/audit

cat > tests/audit/test_log.py <<'EOF'
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import ClassVar

import pytest

from sprout.audit import AuditEvent, FieldChanged, recent, record
from sprout.audit.log import prune
from sprout.config import AUDIT_RETENTION_DAYS
from sprout.db import session
from sprout.models.audit_entry import AuditEntry


@dataclass(frozen=True)
class PlantWatered(AuditEvent):
    kind: ClassVar[str] = "test.plant_watered"

    plant_id: int

    def subject(self):
        return ("plant", self.plant_id)

    def details(self):
        return {"plant_id": self.plant_id}


def test_to_record_shape():
    event = FieldChanged(
        actor_id=3, subject_type="plant", subject_id=9, field="name", old="Fig", new="Ficus"
    )
    assert event.to_record() == {
        "kind": "field_changed",
        "actor_id": 3,
        "subject_type": "plant",
        "subject_id": 9,
        "details": {"field": "name", "old": "Fig", "new": "Ficus"},
    }


def test_record_persists_entry(make_user):
    fern = make_user("fern")
    entry = record(PlantWatered(actor_id=fern.id, plant_id=4))
    session.commit()
    stored = session.get(AuditEntry, entry.id)
    assert stored.kind == "test.plant_watered"
    assert (stored.subject_type, stored.subject_id) == ("plant", 4)
    assert stored.details == {"plant_id": 4}


def test_record_is_not_committed_on_its_own(make_user):
    fern = make_user("fern")
    record(PlantWatered(actor_id=fern.id, plant_id=4))
    session.rollback()
    assert session.query(AuditEntry).count() == 0


def test_recent_newest_first(make_user):
    fern = make_user("fern")
    base = datetime(2026, 2, 1, tzinfo=timezone.utc)
    for offset, plant_id in enumerate([1, 2, 3]):
        record(
            PlantWatered(actor_id=fern.id, plant_id=plant_id),
            occurred_at=base + timedelta(hours=offset),
        )
    session.commit()
    assert [e.details["plant_id"] for e in recent(fern.id)] == [3, 2, 1]


def test_recent_filters_by_actor(make_user):
    fern, ivy = make_user("fern"), make_user("ivy")
    record(PlantWatered(actor_id=fern.id, plant_id=1))
    record(PlantWatered(actor_id=ivy.id, plant_id=2))
    session.commit()
    assert [e.details["plant_id"] for e in recent(ivy.id)] == [2]


def test_recent_respects_limit(make_user):
    fern = make_user("fern")
    for plant_id in range(5):
        record(PlantWatered(actor_id=fern.id, plant_id=plant_id))
    session.commit()
    assert len(recent(fern.id, limit=2)) == 2


def test_recent_rejects_nonpositive_limit(make_user):
    fern = make_user("fern")
    with pytest.raises(ValueError):
        recent(fern.id, limit=0)


def test_prune_drops_entries_past_retention(make_user):
    fern = make_user("fern")
    now = datetime(2026, 6, 1, tzinfo=timezone.utc)
    record(
        PlantWatered(actor_id=fern.id, plant_id=1),
        occurred_at=now - timedelta(days=AUDIT_RETENTION_DAYS + 1),
    )
    record(PlantWatered(actor_id=fern.id, plant_id=2), occurred_at=now - timedelta(days=1))
    session.commit()
    assert prune(now=now) == 1
    assert [e.details["plant_id"] for e in recent(fern.id)] == [2]
EOF

cat > tests/workspaces/test_service.py <<'EOF'
import pytest

from sprout.audit import MemberAdded, MemberRemoved
from sprout.db import session
from sprout.models.audit_entry import AuditEntry
from sprout.workspaces import service


def _kinds():
    return [entry.kind for entry in session.query(AuditEntry).order_by(AuditEntry.id)]


def test_create_workspace_makes_creator_owner(make_user):
    fern = make_user("fern")
    workspace = service.create_workspace(fern, "Balcony Garden")
    assert workspace.slug == "balcony-garden"
    membership = service.membership_for(workspace, fern)
    assert membership.role == "owner"
    assert _kinds() == [MemberAdded.kind]


def test_slugs_are_unique(make_user):
    fern = make_user("fern")
    first = service.create_workspace(fern, "Balcony")
    second = service.create_workspace(fern, "Balcony")
    assert (first.slug, second.slug) == ("balcony", "balcony-2")


def test_add_member_records_audit_entry(make_user):
    fern, ivy = make_user("fern"), make_user("ivy")
    workspace = service.create_workspace(fern, "Balcony")
    service.add_member(workspace, fern, ivy, role="editor")
    entry = session.query(AuditEntry).order_by(AuditEntry.id.desc()).first()
    assert entry.kind == MemberAdded.kind
    assert entry.actor_id == fern.id
    assert entry.details["member_id"] == ivy.id
    assert entry.details["role"] == "editor"


def test_add_member_twice_raises(make_user):
    fern, ivy = make_user("fern"), make_user("ivy")
    workspace = service.create_workspace(fern, "Balcony")
    service.add_member(workspace, fern, ivy)
    with pytest.raises(service.AlreadyMember):
        service.add_member(workspace, fern, ivy)


def test_remove_member_records_audit_entry(make_user):
    fern, ivy = make_user("fern"), make_user("ivy")
    workspace = service.create_workspace(fern, "Balcony")
    service.add_member(workspace, fern, ivy)
    service.remove_member(workspace, fern, ivy)
    assert service.membership_for(workspace, ivy) is None
    assert _kinds()[-1] == MemberRemoved.kind


def test_cannot_remove_last_owner(make_user):
    fern = make_user("fern")
    workspace = service.create_workspace(fern, "Balcony")
    with pytest.raises(service.LastOwner):
        service.remove_member(workspace, fern, fern)


def test_personal_workspace_is_reused(make_user):
    fern = make_user("fern")
    first = service.personal_workspace_for(fern)
    second = service.personal_workspace_for(fern)
    assert first.id == second.id
    assert first.is_personal


def test_workspaces_for_lists_personal_first(make_user):
    fern = make_user("fern")
    service.create_workspace(fern, "Allotment")
    service.personal_workspace_for(fern)
    names = [workspace.name for workspace in service.workspaces_for(fern)]
    assert names == ["Fern's plants", "Allotment"]
EOF

cat > tests/workspaces/test_workspaces_api.py <<'EOF'
def test_create_and_list(client, make_user, as_user):
    fern = make_user("fern")
    resp = client.post("/workspaces", json={"name": "Balcony"}, headers=as_user(fern))
    assert resp.status_code == 201
    listed = client.get("/workspaces", headers=as_user(fern)).get_json()
    assert [w["slug"] for w in listed] == ["balcony"]


def test_show_hidden_from_non_members(client, make_user, make_workspace, as_user):
    fern, ivy = make_user("fern"), make_user("ivy")
    balcony = make_workspace(fern, "Balcony")
    assert client.get(f"/workspaces/{balcony.slug}", headers=as_user(ivy)).status_code == 404


def test_show_includes_members(client, make_user, make_workspace, as_user):
    fern, ivy = make_user("fern"), make_user("ivy")
    balcony = make_workspace(fern, "Balcony", members=[(ivy, "viewer")])
    data = client.get(f"/workspaces/{balcony.slug}", headers=as_user(ivy)).get_json()
    assert {m["username"]: m["role"] for m in data["members"]} == {"fern": "owner", "ivy": "viewer"}


def test_owner_adds_member_by_username(client, make_user, make_workspace, as_user):
    fern, _ivy = make_user("fern"), make_user("ivy")
    balcony = make_workspace(fern, "Balcony")
    resp = client.post(
        f"/workspaces/{balcony.slug}/members",
        json={"username": "ivy", "role": "editor"},
        headers=as_user(fern),
    )
    assert resp.status_code == 201
    assert resp.get_json()["role"] == "editor"


def test_editor_cannot_add_members(client, make_user, make_workspace, as_user):
    fern, ivy, _moss = make_user("fern"), make_user("ivy"), make_user("moss")
    balcony = make_workspace(fern, "Balcony", members=[(ivy, "editor")])
    resp = client.post(
        f"/workspaces/{balcony.slug}/members", json={"username": "moss"}, headers=as_user(ivy)
    )
    assert resp.status_code == 403


def test_last_owner_cannot_leave(client, make_user, make_workspace, as_user):
    fern = make_user("fern")
    balcony = make_workspace(fern, "Balcony")
    resp = client.delete(f"/workspaces/{balcony.slug}/members/{fern.id}", headers=as_user(fern))
    assert resp.status_code == 409
EOF

cat > tests/workspaces/test_invites.py <<'EOF'
from datetime import timedelta

import pytest

from sprout.db import session
from sprout.workspaces import invites, service


def test_accepting_invite_adds_member(make_user, make_workspace):
    fern, ivy = make_user("fern"), make_user("ivy")
    balcony = make_workspace(fern, "Balcony")
    invite, token = invites.create_invite(balcony, fern, role="editor")
    membership = invites.accept_invite(token, ivy)
    assert membership.role == "editor"
    session.refresh(invite)
    assert invite.use_count == 1


def test_single_use_invite_is_used_up(make_user, make_workspace, invite_token):
    fern, ivy, moss = make_user("fern"), make_user("ivy"), make_user("moss")
    balcony = make_workspace(fern, "Balcony")
    token = invite_token(balcony, fern)
    invites.accept_invite(token, ivy)
    with pytest.raises(invites.InviteUsedUp):
        invites.accept_invite(token, moss)


def test_revoked_invite_is_rejected(make_user, make_workspace):
    fern, ivy = make_user("fern"), make_user("ivy")
    balcony = make_workspace(fern, "Balcony")
    invite, token = invites.create_invite(balcony, fern)
    invites.revoke_invite(invite, fern)
    with pytest.raises(invites.RevokedInvite):
        invites.accept_invite(token, ivy)


def test_expired_token_is_rejected(app, make_user, make_workspace):
    fern, ivy = make_user("fern"), make_user("ivy")
    balcony = make_workspace(fern, "Balcony")
    _invite, token = invites.create_invite(balcony, fern)
    app.config["INVITE_MAX_AGE"] = timedelta(seconds=-1)
    with pytest.raises(invites.ExpiredInvite):
        invites.accept_invite(token, ivy)


def test_viewer_cannot_create_invites(client, make_user, make_workspace, as_user):
    fern, ivy = make_user("fern"), make_user("ivy")
    balcony = make_workspace(fern, "Balcony", members=[(ivy, "viewer")])
    resp = client.post(f"/workspaces/{balcony.slug}/invites", json={}, headers=as_user(ivy))
    assert resp.status_code == 403


def test_invite_flow_over_http(client, make_user, make_workspace, as_user):
    fern, ivy = make_user("fern"), make_user("ivy")
    balcony = make_workspace(fern, "Balcony")
    created = client.post(
        f"/workspaces/{balcony.slug}/invites", json={"role": "viewer"}, headers=as_user(fern)
    )
    assert created.status_code == 201
    path = created.get_json()["url"].replace("http://localhost", "")
    page = client.get(path, headers=as_user(ivy))
    assert page.status_code == 200
    assert b"Join Balcony" in page.data
    accepted = client.post(f"{path}/accept", headers=as_user(ivy))
    assert accepted.status_code == 302
    assert service.membership_for(balcony, ivy).role == "viewer"


def test_bad_link_renders_error_page(client, make_user, as_user):
    ivy = make_user("ivy")
    resp = client.get("/workspaces/invites/not-a-real-token", headers=as_user(ivy))
    assert resp.status_code == 410
    assert b"can't be used" in resp.data
EOF

commit_at "2026-02-24T16:15:00+00:00" -m "Tests for audit log, workspace service/routes and invites"

# --- F9: address review feedback (touches several areas) -------------------
cat > sprout/audit/log.py <<'EOF'
"""Write and read the audit trail."""
from __future__ import annotations

import json
from datetime import datetime, timedelta

from sqlalchemy import delete, select

from sprout.audit.events import AuditEvent
from sprout.config import AUDIT_RETENTION_DAYS
from sprout.db import session, utcnow
from sprout.models.audit_entry import AuditEntry

#: Hard ceiling for :func:`recent`, whatever the caller asks for.
MAX_LIMIT = 200


def record(event: AuditEvent, *, occurred_at: datetime | None = None) -> AuditEntry:
    """Stage an audit entry for ``event`` in the current session.

    The entry is flushed but not committed: it becomes durable together with
    whatever change the caller is making, or not at all.
    """
    if not isinstance(event, AuditEvent):
        raise TypeError(f"record() expects an AuditEvent, got {type(event).__name__}")
    data = event.to_record()
    entry = AuditEntry(
        occurred_at=occurred_at or utcnow(),
        actor_id=data["actor_id"],
        kind=data["kind"],
        subject_type=data["subject_type"],
        subject_id=data["subject_id"],
        details_json=json.dumps(data["details"], sort_keys=True, separators=(",", ":")),
    )
    session.add(entry)
    session.flush()
    return entry


def recent(actor_id: int, limit: int = 50) -> list[AuditEntry]:
    """The most recent entries recorded for ``actor_id``, newest first.

    ``limit`` is clamped to :data:`MAX_LIMIT` so a query-string value can
    never turn into an unbounded scan.
    """
    if limit <= 0:
        raise ValueError("limit must be positive")
    limit = min(limit, MAX_LIMIT)
    stmt = (
        select(AuditEntry)
        .where(AuditEntry.actor_id == actor_id)
        .order_by(AuditEntry.occurred_at.desc(), AuditEntry.id.desc())
        .limit(limit)
    )
    return list(session.scalars(stmt))


def prune(now: datetime | None = None) -> int:
    """Delete entries older than :data:`sprout.config.AUDIT_RETENTION_DAYS`.

    Returns the number of rows removed. Commits: pruning is housekeeping and
    never part of a larger change.
    """
    cutoff = (now or utcnow()) - timedelta(days=AUDIT_RETENTION_DAYS)
    result = session.execute(delete(AuditEntry).where(AuditEntry.occurred_at < cutoff))
    session.commit()
    return result.rowcount
EOF

cat > sprout/workspaces/service.py <<'EOF'
"""Workspace lifecycle: creation, membership changes and lookups.

Every membership change is written to the audit log in the same transaction
as the change itself, so the audit trail can never drift from reality.
"""
from __future__ import annotations

import re

from slugify import slugify
from sqlalchemy import func, select

from sprout.audit import MemberAdded, MemberRemoved, record
from sprout.db import session
from sprout.models.membership import ROLES, Membership
from sprout.models.user import User
from sprout.models.workspace import Workspace

MAX_NAME_LENGTH = 80
SLUG_MAX_LENGTH = 48
_WHITESPACE = re.compile(r"\s+")


class WorkspaceError(Exception):
    """Base class for workspace rule violations surfaced to API callers."""


class InvalidName(WorkspaceError):
    pass


class UnknownRole(WorkspaceError):
    pass


class AlreadyMember(WorkspaceError):
    pass


class NotAMember(WorkspaceError):
    pass


class LastOwner(WorkspaceError):
    """Raised when a change would leave a workspace with no owner."""


class PersonalWorkspace(WorkspaceError):
    """Raised when trying to share a personal workspace."""


def _clean_name(name: str) -> str:
    name = _WHITESPACE.sub(" ", name or "").strip()
    if not name:
        raise InvalidName("workspace name cannot be blank")
    if len(name) > MAX_NAME_LENGTH:
        raise InvalidName(f"workspace name must be at most {MAX_NAME_LENGTH} characters")
    return name


def _check_role(role: str) -> str:
    if role not in ROLES:
        raise UnknownRole(f"unknown role {role!r}; expected one of {', '.join(ROLES)}")
    return role


def unique_slug(name: str) -> str:
    """A URL-safe slug for ``name`` that no other workspace uses yet."""
    base = slugify(name, max_length=SLUG_MAX_LENGTH, word_boundary=True) or "workspace"
    candidate = base
    suffix = 2
    while session.scalar(select(Workspace.id).where(Workspace.slug == candidate)) is not None:
        candidate = f"{base}-{suffix}"
        suffix += 1
    return candidate


def get_by_slug(slug: str) -> Workspace | None:
    return session.scalar(select(Workspace).where(Workspace.slug == slug))


def workspaces_for(user: User) -> list[Workspace]:
    """Every workspace ``user`` belongs to, personal one first, then by name."""
    stmt = (
        select(Workspace)
        .join(Membership, Membership.workspace_id == Workspace.id)
        .where(Membership.user_id == user.id)
        .order_by(Workspace.is_personal.desc(), Workspace.name)
    )
    return list(session.scalars(stmt))


def membership_for(workspace: Workspace, user: User | None) -> Membership | None:
    if user is None:
        return None
    return session.scalar(
        select(Membership).where(
            Membership.workspace_id == workspace.id,
            Membership.user_id == user.id,
        )
    )


def _owner_count(workspace: Workspace) -> int:
    return session.scalar(
        select(func.count(Membership.id)).where(
            Membership.workspace_id == workspace.id,
            Membership.role == "owner",
        )
    )


def create_workspace(creator: User, name: str, *, personal: bool = False) -> Workspace:
    """Create a workspace with ``creator`` as its first owner."""
    name = _clean_name(name)
    workspace = Workspace(
        name=name,
        slug=unique_slug(name),
        created_by_id=creator.id,
        is_personal=personal,
    )
    session.add(workspace)
    session.flush()
    session.add(Membership(workspace_id=workspace.id, user_id=creator.id, role="owner"))
    record(MemberAdded.for_workspace(creator.id, workspace, member_id=creator.id, role="owner"))
    session.commit()
    return workspace


def personal_workspace_for(user: User) -> Workspace:
    """The user's personal workspace, created on first use."""
    existing = session.scalar(
        select(Workspace).where(
            Workspace.created_by_id == user.id,
            Workspace.is_personal.is_(True),
        )
    )
    if existing is not None:
        return existing
    label = user.display_name or user.username
    return create_workspace(user, f"{label}'s plants", personal=True)


def add_member(
    workspace: Workspace,
    actor: User,
    user: User,
    role: str = "viewer",
    *,
    commit: bool = True,
) -> Membership:
    """Add ``user`` to ``workspace``. ``actor`` is who made the change."""
    _check_role(role)
    if workspace.is_personal:
        raise PersonalWorkspace("personal workspaces cannot be shared; create a new one")
    if membership_for(workspace, user) is not None:
        raise AlreadyMember(f"{user.username} is already a member of {workspace.name}")
    membership = Membership(workspace_id=workspace.id, user_id=user.id, role=role)
    session.add(membership)
    session.flush()
    record(MemberAdded.for_workspace(actor.id, workspace, member_id=user.id, role=role))
    if commit:
        session.commit()
    return membership


def remove_member(workspace: Workspace, actor: User, user: User) -> None:
    """Remove ``user`` from ``workspace``; the last owner cannot be removed."""
    membership = membership_for(workspace, user)
    if membership is None:
        raise NotAMember(f"{user.username} is not a member of {workspace.name}")
    if membership.role == "owner" and _owner_count(workspace) == 1:
        raise LastOwner("a workspace needs at least one owner")
    session.delete(membership)
    record(MemberRemoved.for_workspace(actor.id, workspace, member_id=user.id))
    session.commit()
EOF

cat > sprout/workspaces/invites.py <<'EOF'
"""Signed, shareable invite links for workspaces.

An invite link carries a token signed with the app's ``SECRET_KEY``. The token
only names an :class:`~sprout.models.invite.Invite` row by its nonce; the row
is the source of truth for role, remaining uses and revocation, so a leaked
link can be killed without rotating the key.
"""
from __future__ import annotations

import secrets
from datetime import timedelta

from flask import current_app
from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer
from sqlalchemy import select

from sprout.db import session, utcnow
from sprout.models.invite import Invite
from sprout.models.membership import ROLES, Membership
from sprout.models.user import User
from sprout.models.workspace import Workspace
from sprout.workspaces import service

TOKEN_SALT = "sprout.workspace-invite.v1"
DEFAULT_MAX_AGE = timedelta(days=7)
MAX_USES_LIMIT = 50


class InviteError(Exception):
    """Base class for every reason an invite cannot be created or used."""


class InvalidInvite(InviteError):
    pass


class ExpiredInvite(InviteError):
    pass


class RevokedInvite(InviteError):
    pass


class InviteUsedUp(InviteError):
    pass


def _serializer() -> URLSafeTimedSerializer:
    return URLSafeTimedSerializer(current_app.config["SECRET_KEY"], salt=TOKEN_SALT)


def _max_age() -> timedelta:
    return current_app.config.get("INVITE_MAX_AGE", DEFAULT_MAX_AGE)


def create_invite(
    workspace: Workspace, inviter: User, *, role: str = "viewer", max_uses: int = 1
) -> tuple[Invite, str]:
    """Create an invite row and return it with its signed token."""
    if role not in ROLES or role == "owner":
        raise InvalidInvite(f"invites cannot grant the {role!r} role")
    if not 1 <= max_uses <= MAX_USES_LIMIT:
        raise InvalidInvite(f"max_uses must be between 1 and {MAX_USES_LIMIT}")
    if workspace.is_personal:
        raise InvalidInvite("personal workspaces cannot be shared")
    invite = Invite(
        workspace_id=workspace.id,
        created_by_id=inviter.id,
        role=role,
        nonce=secrets.token_urlsafe(24),
        max_uses=max_uses,
        expires_at=utcnow() + _max_age(),
    )
    session.add(invite)
    session.commit()
    return invite, sign_invite(invite)


def sign_invite(invite: Invite) -> str:
    """The signed link token for an existing invite row."""
    return _serializer().dumps({"n": invite.nonce, "w": invite.workspace_id})


def load_invite(token: str) -> Invite:
    """Verify ``token`` and return its live invite, or raise :class:`InviteError`."""
    try:
        data = _serializer().loads(token, max_age=int(_max_age().total_seconds()))
    except SignatureExpired as exc:
        raise ExpiredInvite("this invite link has expired") from exc
    except BadSignature as exc:
        raise InvalidInvite("this invite link is not valid") from exc
    invite = session.scalar(select(Invite).where(Invite.nonce == data.get("n")))
    if invite is None or invite.workspace_id != data.get("w"):
        raise InvalidInvite("this invite link is not valid")
    if invite.revoked_at is not None:
        raise RevokedInvite("this invite was revoked")
    if invite.uses_left == 0:
        raise InviteUsedUp("this invite has already been used")
    return invite


def accept_invite(token: str, user: User) -> Membership:
    """Join the invite's workspace. Accepting twice is harmless.

    The invite is only honoured while the person who sent it is still an
    owner of the workspace; removing them retires their links.
    """
    invite = load_invite(token)
    existing = service.membership_for(invite.workspace, user)
    if existing is not None:
        return existing
    inviter_membership = service.membership_for(invite.workspace, invite.created_by)
    if inviter_membership is None or not inviter_membership.has_role("owner"):
        raise RevokedInvite("the person who sent this invite can no longer add members")
    membership = service.add_member(
        invite.workspace, invite.created_by, user, role=invite.role, commit=False
    )
    invite.use_count += 1
    session.commit()
    return membership


def revoke_invite(invite: Invite, actor: User) -> None:
    invite.revoked_at = utcnow()
    invite.revoked_by_id = actor.id
    session.commit()
EOF

cat > sprout/permissions.py <<'EOF'
"""Central permission table.

Every protected action is named ``<resource>:<verb>``. ``PERMISSIONS`` maps the
action name to a predicate ``(actor, obj) -> bool``. Views call :func:`can`
rather than checking ownership inline, so the rules live in one place.

Callers pass an :class:`Actor`, not a bare user: the actor carries the user
plus, when the caller already has it, their membership in the workspace the
request is about, which saves a query per check.

Plants and workspaces are governed by workspace roles (see
:data:`sprout.models.membership.ROLE_RANK`): an actor may act on an object when
their role in the object's workspace is at least the role the action needs.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable

from sqlalchemy import select

from sprout.db import session
from sprout.models.membership import ROLE_RANK, Membership
from sprout.models.user import User


@dataclass(frozen=True)
class Actor:
    """The user performing an action, plus an optional pre-loaded membership."""

    user: User
    membership: Membership | None = None

    @property
    def id(self) -> int:
        return self.user.id

    def role_in(self, workspace_id: int | None) -> str | None:
        """The actor's role in ``workspace_id``, or ``None`` if not a member."""
        if workspace_id is None:
            return None
        if self.membership is not None and self.membership.workspace_id == workspace_id:
            return self.membership.role
        return session.scalar(
            select(Membership.role).where(
                Membership.workspace_id == workspace_id,
                Membership.user_id == self.user.id,
            )
        )


def actor_for(user: User | None, workspace=None) -> Actor | None:
    """Wrap ``user`` as an :class:`Actor`, preloading their membership in ``workspace``."""
    if user is None:
        return None
    membership = None
    if workspace is not None:
        membership = session.scalar(
            select(Membership).where(
                Membership.workspace_id == workspace.id,
                Membership.user_id == user.id,
            )
        )
    return Actor(user=user, membership=membership)


Predicate = Callable[[Actor, Any], bool]


def _rank(role: str | None) -> int:
    return ROLE_RANK.get(role, 0) if role else 0


def _is_owner(actor: Actor, plant) -> bool:
    return plant.owner_id == actor.id


def _plant_role_at_least(minimum: str) -> Predicate:
    needed = ROLE_RANK[minimum]

    def predicate(actor: Actor, plant) -> bool:
        if plant.workspace_id is None:
            # Rows not yet backfilled by migration 0006 fall back to ownership.
            return _is_owner(actor, plant)
        return _rank(actor.role_in(plant.workspace_id)) >= needed

    predicate.__name__ = f"plant_role_at_least_{minimum}"
    return predicate


def _workspace_role_at_least(minimum: str) -> Predicate:
    needed = ROLE_RANK[minimum]

    def predicate(actor: Actor, workspace) -> bool:
        return _rank(actor.role_in(workspace.id)) >= needed

    predicate.__name__ = f"workspace_role_at_least_{minimum}"
    return predicate


PERMISSIONS: dict[str, Predicate] = {
    "plant:read": _plant_role_at_least("viewer"),
    "plant:update": _plant_role_at_least("editor"),
    "plant:delete": _plant_role_at_least("editor"),
    "plant:water": _plant_role_at_least("editor"),
    # Moving a plant out of a workspace is an editor action in the *source*
    # workspace; the target workspace is checked separately via add_plant.
    "plant:move": _plant_role_at_least("editor"),
    "workspace:read": _workspace_role_at_least("viewer"),
    "workspace:add_plant": _workspace_role_at_least("editor"),
    "workspace:manage_members": _workspace_role_at_least("owner"),
}


def can(actor: Actor | None, action: str, obj: Any = None) -> bool:
    """Return True if ``actor`` may perform ``action`` on ``obj``.

    Anonymous callers (``None``) can do nothing. Passing a bare ``User`` is a
    programming error: wrap it with :func:`actor_for` first. Unknown actions
    raise ``KeyError`` rather than silently denying.
    """
    if actor is None:
        return False
    if not isinstance(actor, Actor):
        raise TypeError(f"can() expects an Actor, got {type(actor).__name__}; use actor_for()")
    try:
        predicate = PERMISSIONS[action]
    except KeyError:
        raise KeyError(f"unknown permission {action!r}") from None
    return bool(predicate(actor, obj))


# --- Invite links ------------------------------------------------------------


def _invite_is_usable(actor: Actor, invite) -> bool:
    """Anyone signed in may accept a live invite, unless they already belong."""
    return invite.is_usable() and actor.role_in(invite.workspace_id) is None


PERMISSIONS.update(
    {
        "invite:create": _workspace_role_at_least("owner"),
        "invite:revoke": _workspace_role_at_least("owner"),
        "invite:accept": _invite_is_usable,
    }
)
EOF

cat > sprout/plants/api.py <<'EOF'
"""JSON API for plants.

Plants live in workspaces. A user sees every plant in every workspace they
belong to; changing a plant needs at least the ``editor`` role there. Plants
created without an explicit workspace land in the user's personal workspace.
"""
from __future__ import annotations

from flask import Blueprint, abort, g, jsonify, request
from sqlalchemy import select

from sprout.audit import PlantMoved, record
from sprout.auth import login_required
from sprout.db import session
from sprout.models.membership import Membership
from sprout.models.plant import Plant
from sprout.permissions import actor_for, can
from sprout.workspaces import service as workspace_service

bp = Blueprint("plants", __name__, url_prefix="/api/plants")

EDITABLE_FIELDS = ("name", "species", "location", "watering_interval_days")
MAX_INTERVAL_DAYS = 365


def _actor():
    return actor_for(g.user)


def _visible_plants():
    """Plants in any workspace the current user is a member of."""
    member_of = select(Membership.workspace_id).where(Membership.user_id == g.user.id)
    return select(Plant).where(Plant.workspace_id.in_(member_of))


def _load_plant_or_404(plant_id: int) -> Plant:
    plant = session.get(Plant, plant_id)
    if plant is None or not can(_actor(), "plant:read", plant):
        abort(404)
    return plant


def _workspace_or_404(slug: str):
    workspace = workspace_service.get_by_slug(slug)
    if workspace is None or not can(_actor(), "workspace:read", workspace):
        abort(404)
    return workspace


def _apply_changes(plant: Plant, payload: dict) -> str | None:
    """Copy editable fields from ``payload``; return an error message or None."""
    for field in EDITABLE_FIELDS:
        if field not in payload:
            continue
        value = payload[field]
        if field == "name":
            value = (value or "").strip()
            if not value:
                return "name cannot be blank"
        if field == "watering_interval_days":
            if not isinstance(value, int) or not 1 <= value <= MAX_INTERVAL_DAYS:
                return f"watering_interval_days must be between 1 and {MAX_INTERVAL_DAYS}"
        setattr(plant, field, value)
    return None


@bp.get("")
@login_required
def list_plants():
    stmt = _visible_plants()
    slug = request.args.get("workspace")
    if slug:
        workspace = _workspace_or_404(slug)
        stmt = stmt.where(Plant.workspace_id == workspace.id)
    plants = session.scalars(stmt.order_by(Plant.name, Plant.id)).all()
    return jsonify([plant.to_dict() for plant in plants])


@bp.post("")
@login_required
def create_plant():
    payload = request.get_json(silent=True) or {}
    payload.setdefault("name", "")
    if payload.get("workspace"):
        workspace = _workspace_or_404(payload["workspace"])
    else:
        workspace = workspace_service.personal_workspace_for(g.user)
    if not can(_actor(), "workspace:add_plant", workspace):
        abort(403)
    plant = Plant(owner_id=g.user.id, workspace_id=workspace.id, name="")
    error = _apply_changes(plant, payload)
    if error:
        return jsonify(error=error), 400
    session.add(plant)
    session.commit()
    return jsonify(plant.to_dict()), 201


@bp.patch("/<int:plant_id>")
@login_required
def update_plant(plant_id: int):
    plant = _load_plant_or_404(plant_id)
    if not can(_actor(), "plant:update", plant):
        abort(403)
    error = _apply_changes(plant, request.get_json(silent=True) or {})
    if error:
        session.rollback()
        return jsonify(error=error), 400
    session.commit()
    return jsonify(plant.to_dict())


@bp.post("/<int:plant_id>/move")
@login_required
def move_plant(plant_id: int):
    """Move a plant into another workspace the user can add plants to."""
    plant = _load_plant_or_404(plant_id)
    payload = request.get_json(silent=True) or {}
    target = _workspace_or_404(payload.get("workspace") or "")
    actor = _actor()
    if not can(actor, "plant:move", plant) or not can(actor, "workspace:add_plant", target):
        abort(403)
    if target.id == plant.workspace_id:
        return jsonify(plant.to_dict())
    source_id = plant.workspace_id
    plant.workspace_id = target.id
    record(
        PlantMoved.for_workspace(
            g.user.id, target, plant_id=plant.id, from_workspace_id=source_id
        )
    )
    session.commit()
    return jsonify(plant.to_dict())
EOF

cat > tests/audit/test_log.py <<'EOF'
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import ClassVar

import pytest

from sprout.audit import AuditEvent, FieldChanged, recent, record
from sprout.audit.log import MAX_LIMIT, prune
from sprout.config import AUDIT_RETENTION_DAYS
from sprout.db import session
from sprout.models.audit_entry import AuditEntry


@dataclass(frozen=True)
class PlantWatered(AuditEvent):
    kind: ClassVar[str] = "test.plant_watered"

    plant_id: int

    def subject(self):
        return ("plant", self.plant_id)

    def details(self):
        return {"plant_id": self.plant_id}


def test_to_record_shape():
    event = FieldChanged(
        actor_id=3, subject_type="plant", subject_id=9, field="name", old="Fig", new="Ficus"
    )
    assert event.to_record() == {
        "kind": "field_changed",
        "actor_id": 3,
        "subject_type": "plant",
        "subject_id": 9,
        "details": {"field": "name", "old": "Fig", "new": "Ficus"},
    }


def test_record_persists_entry(make_user):
    fern = make_user("fern")
    entry = record(PlantWatered(actor_id=fern.id, plant_id=4))
    session.commit()
    stored = session.get(AuditEntry, entry.id)
    assert stored.kind == "test.plant_watered"
    assert (stored.subject_type, stored.subject_id) == ("plant", 4)
    assert stored.details == {"plant_id": 4}


def test_record_is_not_committed_on_its_own(make_user):
    fern = make_user("fern")
    record(PlantWatered(actor_id=fern.id, plant_id=4))
    session.rollback()
    assert session.query(AuditEntry).count() == 0


def test_recent_newest_first(make_user):
    fern = make_user("fern")
    base = datetime(2026, 2, 1, tzinfo=timezone.utc)
    for offset, plant_id in enumerate([1, 2, 3]):
        record(
            PlantWatered(actor_id=fern.id, plant_id=plant_id),
            occurred_at=base + timedelta(hours=offset),
        )
    session.commit()
    assert [e.details["plant_id"] for e in recent(fern.id)] == [3, 2, 1]


def test_recent_filters_by_actor(make_user):
    fern, ivy = make_user("fern"), make_user("ivy")
    record(PlantWatered(actor_id=fern.id, plant_id=1))
    record(PlantWatered(actor_id=ivy.id, plant_id=2))
    session.commit()
    assert [e.details["plant_id"] for e in recent(ivy.id)] == [2]


def test_recent_respects_limit(make_user):
    fern = make_user("fern")
    for plant_id in range(5):
        record(PlantWatered(actor_id=fern.id, plant_id=plant_id))
    session.commit()
    assert len(recent(fern.id, limit=2)) == 2


def test_recent_clamps_huge_limit(make_user):
    fern = make_user("fern")
    for plant_id in range(MAX_LIMIT + 5):
        record(PlantWatered(actor_id=fern.id, plant_id=plant_id))
    session.commit()
    assert len(recent(fern.id, limit=10_000)) == MAX_LIMIT


def test_recent_rejects_nonpositive_limit(make_user):
    fern = make_user("fern")
    with pytest.raises(ValueError):
        recent(fern.id, limit=0)


def test_prune_drops_entries_past_retention(make_user):
    fern = make_user("fern")
    now = datetime(2026, 6, 1, tzinfo=timezone.utc)
    record(
        PlantWatered(actor_id=fern.id, plant_id=1),
        occurred_at=now - timedelta(days=AUDIT_RETENTION_DAYS + 1),
    )
    record(PlantWatered(actor_id=fern.id, plant_id=2), occurred_at=now - timedelta(days=1))
    session.commit()
    assert prune(now=now) == 1
    assert [e.details["plant_id"] for e in recent(fern.id)] == [2]
EOF

cat > tests/workspaces/test_activity.py <<'EOF'
from sprout.workspaces import service
from sprout.workspaces.activity import member_activity


def test_activity_lists_membership_changes_newest_first(make_user, make_workspace):
    fern, ivy = make_user("fern"), make_user("ivy")
    balcony = make_workspace(fern, "Balcony", members=[(ivy, "editor")])
    items = member_activity(balcony)
    assert [item.summary for item in items] == ["added Ivy as editor", "joined as owner"]
    assert items[0].actor_name == "Fern"


def test_activity_ignores_other_workspaces(make_user, make_workspace):
    fern, ivy = make_user("fern"), make_user("ivy")
    balcony = make_workspace(fern, "Balcony")
    make_workspace(fern, "Greenhouse", members=[(ivy, "viewer")])
    summaries = [item.summary for item in member_activity(balcony)]
    assert summaries == ["joined as owner"]


def test_activity_drops_people_who_left(make_user, make_workspace):
    fern, ivy, moss = make_user("fern"), make_user("ivy"), make_user("moss")
    balcony = make_workspace(fern, "Balcony", members=[(ivy, "owner")])
    service.add_member(balcony, ivy, moss, role="viewer")
    service.remove_member(balcony, ivy, ivy)
    actors = {item.actor_name for item in member_activity(balcony)}
    assert actors == {"Fern"}


def test_activity_page_renders_for_members(client, make_user, make_workspace, as_user):
    fern = make_user("fern")
    balcony = make_workspace(fern, "Balcony")
    resp = client.get(f"/workspaces/{balcony.slug}/activity", headers=as_user(fern))
    assert resp.status_code == 200
    assert b"Recent activity in Balcony" in resp.data


def test_activity_page_hidden_from_non_members(client, make_user, make_workspace, as_user):
    fern, ivy = make_user("fern"), make_user("ivy")
    balcony = make_workspace(fern, "Balcony")
    resp = client.get(f"/workspaces/{balcony.slug}/activity", headers=as_user(ivy))
    assert resp.status_code == 404
EOF

cat >> tests/workspaces/test_invites.py <<'EOF'


def test_invite_dies_when_inviter_leaves(make_user, make_workspace):
    fern, ivy, moss = make_user("fern"), make_user("ivy"), make_user("moss")
    balcony = make_workspace(fern, "Balcony", members=[(ivy, "owner")])
    _invite, token = invites.create_invite(balcony, ivy)
    service.remove_member(balcony, fern, ivy)
    with pytest.raises(invites.RevokedInvite):
        invites.accept_invite(token, moss)


def test_personal_workspace_cannot_be_shared(make_user):
    fern = make_user("fern")
    personal = service.personal_workspace_for(fern)
    with pytest.raises(invites.InvalidInvite):
        invites.create_invite(personal, fern)
EOF

cat > README.md <<'EOF'
# Sprout

Sprout is a small web app for keeping houseplants alive. It tracks each
plant, where it lives and how often it wants water, and keeps a care log of
what you did and when.

Plants live in **workspaces**. Everyone starts with a personal workspace;
create more to look after plants together with housemates or family.

## Development

    python -m venv .venv && . .venv/bin/activate
    pip install -e '.[dev]'
    pytest

## Database

Migrations are plain Python files under `migrations/`, applied in filename
order by `sprout.db.apply_migrations`. Each file declares `revision`,
`down_revision`, `upgrade(conn)` and `downgrade(conn)`.

For tests and quick local hacking, `sprout.db.create_all(app)` builds the
schema straight from the models instead.

## Layout

- `sprout/models/` - SQLAlchemy models
- `sprout/auth.py` - loads the signed-in user for each request
- `sprout/config.py` - blueprint list and other static settings
- `sprout/plants/` - plant JSON API
- `sprout/carelog/` - care-log JSON API
- `sprout/workspaces/` - workspaces, members, invite links, member activity
- `sprout/audit/` - append-only audit trail (`record()` / `recent()`)
- `sprout/permissions.py` - the permission table and `can()`
- `sprout/templates/` - Jinja templates

## Permissions

Views never check ownership inline. Each protected action has a name such as
`plant:update`, and `sprout.permissions.PERMISSIONS` maps it to a predicate.
Call `can(user, "plant:update", plant)` and add new rules to the table.

Workspace roles, from least to most powerful:

| Role   | Can                                                   |
|--------|-------------------------------------------------------|
| viewer | see the workspace and its plants                      |
| editor | add, edit and move plants                             |
| owner  | everything above, plus manage members and invite links |

## Invite links

Owners can mint invite links (`POST /workspaces/<slug>/invites`). Links are
signed with `SECRET_KEY`, expire after `INVITE_MAX_AGE` (default seven days),
can be limited to a number of uses and can be revoked at any time.
EOF

commit_at "2026-02-27T12:00:00+00:00" -m "Address review: clamp audit recent(), guard personal workspaces, retire invites from owners who left, plant:move permission"

git checkout -q feature/team-workspaces
