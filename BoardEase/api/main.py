import hashlib
import os
import secrets
from datetime import date
from decimal import Decimal
from typing import Annotated, Literal

import bcrypt
import psycopg
from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from psycopg import IsolationLevel, OperationalError, errors
from psycopg.rows import dict_row
from availability import BOOKABLE_STATUSES, OPERATIONAL_BLOCKS, occupancy_intervals, peak_occupancy, room_availability
from pydantic import AnyHttpUrl, BaseModel, EmailStr, Field, StringConstraints, model_validator

app = FastAPI()
app.add_middleware(
    CORSMiddleware,
    allow_origins=[origin.strip() for origin in os.getenv(
        "WEB_ORIGINS", "http://localhost:7357,http://127.0.0.1:7357"
    ).split(",") if origin.strip()],
    allow_methods=["GET", "POST", "PUT"],
    allow_headers=["Authorization", "Content-Type"],
)


class Login(BaseModel):
    email: EmailStr = Field(max_length=150)
    password: str = Field(min_length=1, max_length=72)


class Registration(Login):
    full_name: str = Field(min_length=1, max_length=150)
    role: str


def connect():
    database_url = os.getenv("DATABASE_URL")
    if not database_url:
        raise HTTPException(
            status_code=503,
            detail="Database is not configured. Set DATABASE_URL in the FastAPI terminal.",
        )
    try:
        db = psycopg.connect(database_url, row_factory=dict_row, connect_timeout=5)
        db.isolation_level = IsolationLevel.READ_COMMITTED
        return db
    except OperationalError as exc:
        raise HTTPException(
            status_code=503,
            detail="Cannot connect to PostgreSQL. Check that it is running and DATABASE_URL is correct.",
        ) from exc


@app.get("/health")
def health():
    return {"status": "ok", "service": "BoardEase FastAPI"}


@app.get("/health/db")
def database_health():
    with connect() as db:
        db.execute("SELECT 1")
    return {"status": "ok", "database": "connected"}


def error(status, message):
    return JSONResponse({"error": message}, status_code=status)


def token_digest(request: Request):
    scheme, _, token = request.headers.get("Authorization", "").partition(" ")
    if scheme.lower() == "bearer" and token:
        return hashlib.sha256(token.encode()).hexdigest()
    return None


@app.post("/auth/register", status_code=201)
def register(form: Registration):
    password = form.password.encode()
    name = form.full_name.strip()
    if form.role not in {"owner", "tenant"} or not name or not 8 <= len(password) <= 72:
        return error(422, "Enter a name, a valid role, and a password of 8 to 72 bytes.")
    password_hash = bcrypt.hashpw(password, bcrypt.gensalt()).decode()
    try:
        with connect() as db:
            role = db.execute(
                "SELECT role_id FROM public.roles WHERE role_name = %s", (form.role,)
            ).fetchone()
            if not role:
                return error(503, "This account role is not configured.")
            db.execute("SELECT pg_advisory_xact_lock(hashtextextended(%s, 0))",
                       (form.email.lower(),))
            if db.execute("SELECT 1 FROM public.users WHERE lower(email) = %s",
                          (form.email.lower(),)).fetchone():
                return error(409, "An account with that email already exists.")
            db.execute(
                """
                INSERT INTO public.users (role_id, full_name, email, password_hash)
                VALUES (%s, %s, %s, %s)
                """,
                (role["role_id"], name, form.email.lower(), password_hash),
            )
    except psycopg.errors.UniqueViolation:
        return error(409, "An account with that email already exists.")
    return {"message": "Account created. Sign in to continue."}


@app.post("/auth/login")
def login(form: Login):
    with connect() as db:
        rows = db.execute(
            """
            SELECT u.user_id, u.full_name, u.email, u.account_status,
                   u.password_hash, r.role_name AS role
            FROM public.users u JOIN public.roles r USING (role_id)
            WHERE lower(u.email) = %s LIMIT 2
            """,
            (form.email.lower(),),
        ).fetchall()
        if len(rows) != 1 or rows[0]["account_status"] != "active":
            return error(401, "Invalid email or password.")
        user = rows[0]
        stored_hash = user.pop("password_hash")
        try:
            password = form.password.encode()
            verified = len(password) <= 72 and bcrypt.checkpw(password, stored_hash.encode())
        except ValueError:
            verified = False
        if not verified:
            return error(401, "Invalid email or password.")
        token = secrets.token_urlsafe(32)
        db.execute(
            """
            INSERT INTO public.boardease_sessions (token_hash, user_id, expires_at)
            VALUES (%s, %s, now() + interval '12 hours')
            """,
            (hashlib.sha256(token.encode()).hexdigest(), user["user_id"]),
        )
    return {"token": token, "user": user}


@app.get("/auth/me")
def profile(request: Request):
    with connect() as db:
        user = db.execute(
            """
            SELECT u.user_id, u.full_name, u.email, u.account_status, r.role_name AS role
            FROM public.boardease_sessions s JOIN public.users u USING (user_id)
            JOIN public.roles r USING (role_id)
            WHERE s.token_hash = %s AND s.expires_at > now()
                AND s.revoked_at IS NULL AND u.account_status = 'active'
            """,
            (token_digest(request),),
        ).fetchone()
    return user if user else error(401, "Session expired. Please log in again.")


@app.post("/auth/logout")
def logout(request: Request):
    with connect() as db:
        db.execute(
            """
            UPDATE public.boardease_sessions SET revoked_at = now()
            WHERE token_hash = %s AND revoked_at IS NULL
            """,
            (token_digest(request),),
        )
    return {"message": "Logged out."}


@app.get("/properties")
def properties(q: Annotated[str, Query(max_length=150)] = ""):
    with connect() as db:
        return db.execute(
            """
            SELECT p.property_id, p.property_name, p.address, p.description
            FROM public.properties p JOIN public.boardease_listing_status s USING (property_id)
            WHERE s.verified AND s.published AND NOT s.archived
              AND (strpos(lower(p.property_name), lower(%s)) > 0
                   OR strpos(lower(p.address), lower(%s)) > 0)
            ORDER BY p.property_id
            """,
            (q.strip(), q.strip()),
        ).fetchall()



class PropertyInput(BaseModel):
    property_name: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=150)
    ]
    address: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=500)
    ]
    description: Annotated[
        str, StringConstraints(strip_whitespace=True, max_length=2000)
    ] = ""


def profile_user(db, request: Request):
    user = db.execute(
        """
        SELECT u.user_id, r.role_name
        FROM public.boardease_sessions s
        JOIN public.users u USING (user_id)
        JOIN public.roles r USING (role_id)
        WHERE s.token_hash = %s
          AND s.expires_at > now()
          AND s.revoked_at IS NULL
          AND u.account_status = 'active'
        """,
        (token_digest(request),),
    ).fetchone()

    if user is None:
        raise HTTPException(status_code=401, detail="Please sign in again.")
    return user


def require_role(db, request: Request, role: str):
    user = profile_user(db, request)
    if user["role_name"] != role:
        raise HTTPException(status_code=403, detail=f"{role.capitalize()} account required.")
    return user["user_id"]


def require_property_owner(db, request: Request):
    return require_role(db, request, "owner")


@app.get("/owner/properties")
def owner_properties(request: Request):
    with connect() as db:
        owner_id = require_property_owner(db, request)
        return db.execute(
            """
            SELECT p.property_id, p.property_name, p.address, p.description,
                   COALESCE(s.verified AND s.published, false) AS is_public,
                   COALESCE(s.verified, false) AS verified
            FROM public.properties p
            LEFT JOIN public.boardease_listing_status s USING (property_id)
            WHERE p.owner_id = %s
              AND NOT COALESCE(s.archived, false)
            ORDER BY p.property_id DESC
            """,
            (owner_id,),
        ).fetchall()


@app.post("/owner/properties", status_code=201)
def create_property(form: PropertyInput, request: Request):
    with connect() as db:
        owner_id = require_property_owner(db, request)
        db.execute("SELECT 1 FROM public.users WHERE user_id = %s FOR UPDATE", (owner_id,))
        plan = db.execute(
            """
            SELECT plan.property_limit
            FROM public.owner_subscriptions sub
            JOIN public.subscription_plans plan USING (plan_id)
            WHERE sub.owner_id = %s AND sub.subscription_status = 'active'
              AND sub.payment_status IN ('paid', 'completed')
              AND CURRENT_DATE BETWEEN sub.start_date AND sub.end_date
            ORDER BY sub.end_date DESC, sub.subscription_id DESC LIMIT 1
            """, (owner_id,),
        ).fetchone()
        if plan is not None and plan["property_limit"] is not None:
            count = db.execute(
                """
                SELECT count(*) AS total FROM public.properties AS p
                LEFT JOIN public.boardease_listing_status AS s USING (property_id)
                WHERE p.owner_id = %s AND NOT COALESCE(s.archived, FALSE)
                """, (owner_id,),
            ).fetchone()["total"]
            if count >= plan["property_limit"]:
                raise HTTPException(409, "Your subscription property limit has been reached.")
        property_row = db.execute(
            """
            INSERT INTO public.properties
                (owner_id, property_name, address, description)
            VALUES (%s, %s, %s, %s)
            RETURNING property_id, property_name, address, description
            """,
            (owner_id, form.property_name, form.address, form.description or None),
        ).fetchone()

        db.execute(
            """
            INSERT INTO public.boardease_listing_status (property_id)
            VALUES (%s)
            """,
            (property_row["property_id"],),
        )

    return {**property_row, "is_public": False}



class RoomInput(BaseModel):
    room_number: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1)]
    capacity: int = Field(default=1, ge=1, le=2147483647)
    monthly_rate: Decimal = Field(gt=0, decimal_places=2)


@app.get("/owner/properties/{property_id}/rooms")
def owner_rooms(
    property_id: int, request: Request, start_date: date | None = None,
    end_date: date | None = None,
):
    with connect() as db:
        owner_id = require_property_owner(db, request)
        if not db.execute(
            "SELECT 1 FROM public.properties WHERE property_id = %s AND owner_id = %s",
            (property_id, owner_id),
        ).fetchone():
            raise HTTPException(404, "Property not found.")
        start, end = availability_dates(db, start_date, end_date)
        return rooms_with_availability(db, property_id, start, end)


@app.post("/owner/properties/{property_id}/rooms", status_code=201)
def create_room(property_id: int, form: RoomInput, request: Request):
    with connect() as db:
        owner_id = require_property_owner(db, request)

        room = db.execute(
            """
            INSERT INTO public.rooms
                (property_id, room_number, capacity, monthly_rate)
            SELECT p.property_id, %s, %s, %s
            FROM public.properties p
            WHERE p.property_id = %s AND p.owner_id = %s
            RETURNING room_id, room_number, capacity, monthly_rate, room_status
            """,
            (form.room_number, form.capacity, form.monthly_rate, property_id, owner_id),
        ).fetchone()
        if room is None:
            raise HTTPException(status_code=404, detail="Property not found.")

        return room


class RoomUpdate(RoomInput):
    room_status: Annotated[str, StringConstraints(strip_whitespace=True)]

    @model_validator(mode="after")
    def validate_status(self):
        self.room_status = self.room_status.lower()
        if self.room_status not in BOOKABLE_STATUSES and self.room_status not in OPERATIONAL_BLOCKS:
            raise ValueError("Select a supported room status.")
        return self


@app.put("/owner/properties/{property_id}/rooms/{room_id}")
def update_owner_room(
    property_id: int,
    room_id: int,
    form: RoomUpdate,
    request: Request,
):
    try:
        with connect() as db:
            owner_id = require_property_owner(db, request)

            current = lock_property_room(db, property_id, room_id, owner_id=owner_id)
            today = db.execute("SELECT CURRENT_DATE AS today").fetchone()["today"]
            if form.capacity < current["capacity"] and form.capacity < peak_occupancy(
                occupancy_intervals(db, room_id), today
            ):
                raise HTTPException(409, "Capacity is below existing occupancy or commitments.")

            room = db.execute(
                """
                UPDATE public.rooms AS r
                SET room_number = %s,
                    capacity = %s,
                    monthly_rate = %s,
                    room_status = %s
                FROM public.properties AS p
                WHERE p.property_id = r.property_id
                  AND p.owner_id = %s
                  AND r.property_id = %s
                  AND r.room_id = %s
                RETURNING r.room_id, r.room_number, r.capacity,
                          r.monthly_rate, r.room_status
                """,
                (
                    form.room_number,
                    form.capacity,
                    form.monthly_rate,
                    form.room_status,
                    owner_id,
                    property_id,
                    room_id,
                ),
            ).fetchone()

            if room is None:
                raise HTTPException(status_code=404, detail="Room not found.")

            return room
    except errors.UniqueViolation as exc:
        raise HTTPException(
            status_code=409, detail="That room number already exists."
        ) from exc
    except (
        errors.CheckViolation,
        errors.StringDataRightTruncation,
        errors.NumericValueOutOfRange,
    ) as exc:
        raise HTTPException(
            status_code=422,
            detail="Check the room number, capacity, monthly rent, and status.",
        ) from exc
class TenantInput(BaseModel):
    full_name: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=150)
    ]
    email: Annotated[
        str, StringConstraints(strip_whitespace=True, max_length=150)
    ] = ""
    phone_number: Annotated[
        str, StringConstraints(strip_whitespace=True, max_length=20)
    ] = ""


@app.get("/owner/properties/{property_id}/rooms/{room_id}/tenants")
def list_room_tenants(property_id: int, room_id: int, request: Request):
    with connect() as db:
        owner_id = require_property_owner(db, request)

        room = db.execute(
            """
            SELECT r.room_id
            FROM public.rooms AS r
            JOIN public.properties AS p ON p.property_id = r.property_id
            WHERE r.room_id = %s AND r.property_id = %s AND p.owner_id = %s
            """,
            (room_id, property_id, owner_id),
        ).fetchone()

        if room is None:
            raise HTTPException(status_code=404, detail="Room not found.")

        return db.execute(
            """
            SELECT tenant_id, full_name, email, phone_number, tenant_status
            FROM public.tenants
            WHERE room_id = %s
            ORDER BY full_name, tenant_id
            """,
            (room_id,),
        ).fetchall()


@app.post(
    "/owner/properties/{property_id}/rooms/{room_id}/tenants",
    status_code=201,
)
def add_room_tenant(
    property_id: int,
    room_id: int,
    form: TenantInput,
    request: Request,
):
    with connect() as db:
        owner_id = require_property_owner(db, request)

        room = db.execute(
            """
            SELECT r.room_id, r.capacity, r.room_status
            FROM public.rooms AS r
            JOIN public.properties AS p ON p.property_id = r.property_id
            WHERE r.room_id = %s AND r.property_id = %s AND p.owner_id = %s
            FOR UPDATE OF r
            """,
            (room_id, property_id, owner_id),
        ).fetchone()

        if room is None:
            raise HTTPException(status_code=404, detail="Room not found.")

        today = db.execute("SELECT CURRENT_DATE AS today").fetchone()["today"]
        check = room_availability(db, room, today, None)
        if not check["is_available"]:
            raise HTTPException(409, check["availability_reason"])

        return db.execute(
            """
            INSERT INTO public.tenants (room_id, full_name, email, phone_number)
            VALUES (%s, %s, %s, %s)
            RETURNING tenant_id, full_name, email, phone_number, tenant_status
            """,
            (room_id, form.full_name, form.email or None, form.phone_number or 		None),
        ).fetchone()
@app.put("/owner/properties/{property_id}/rooms/{room_id}/tenants/{tenant_id}")
def update_room_tenant(
    property_id: int,
    room_id: int,
    tenant_id: int,
    form: TenantInput,
    request: Request,
):
    with connect() as db:
        owner_id = require_property_owner(db, request)

        tenant = db.execute(
            """
            UPDATE public.tenants AS t
            SET full_name = %s,
                email = %s,
                phone_number = %s
            FROM public.rooms AS r
            JOIN public.properties AS p ON p.property_id = r.property_id
            WHERE t.room_id = r.room_id
              AND t.tenant_id = %s
              AND r.room_id = %s
              AND p.property_id = %s
              AND p.owner_id = %s
            RETURNING t.tenant_id, t.full_name, t.email,
                      t.phone_number, t.tenant_status
            """,
            (
                form.full_name,
                form.email or None,
                form.phone_number or None,
                tenant_id,
                room_id,
                property_id,
                owner_id,
            ),
        ).fetchone()

        if tenant is None:
            raise HTTPException(status_code=404, detail="Tenant not found.")

        return tenant



class RentalAgreementInput(BaseModel):
    start_date: date
    end_date: date | None = None
    security_deposit: Decimal = Field(default=Decimal("0"), ge=0, decimal_places=2)

    @model_validator(mode="after")
    def validate_dates(self):
        if self.end_date is not None and self.end_date < self.start_date:
            raise ValueError("End date must be on or after the start date.")
        return self


@app.post(
    "/owner/properties/{property_id}/rooms/{room_id}/tenants/{tenant_id}/agreements",
    status_code=201,
)
def create_rental_agreement(
    property_id: int,
    room_id: int,
    tenant_id: int,
    form: RentalAgreementInput,
    request: Request,
):
    with connect() as db:
        owner_id = require_property_owner(db, request)

        room = lock_property_room(db, property_id, room_id, owner_id=owner_id)

        tenant = db.execute(
            """
            SELECT r.monthly_rate
            FROM public.tenants AS t
            JOIN public.rooms AS r ON r.room_id = t.room_id
            JOIN public.properties AS p ON p.property_id = r.property_id
            WHERE t.tenant_id = %s
              AND r.room_id = %s
              AND p.property_id = %s
              AND p.owner_id = %s
            FOR UPDATE OF t
            """,
            (tenant_id, room_id, property_id, owner_id),
        ).fetchone()

        if tenant is None:
            raise HTTPException(status_code=404, detail="Tenant not found in this room.")

        existing = db.execute(
            """
            SELECT agreement_id
            FROM public.rental_agreements
            WHERE tenant_id = %s
              AND agreement_status IN ('pending', 'active')
              AND (end_date IS NULL OR end_date >= %s)
              AND (%s::date IS NULL OR start_date <= %s::date)
            LIMIT 1
            """,
            (tenant_id, form.start_date, form.end_date, form.end_date),
        ).fetchone()

        if existing is not None:
            raise HTTPException(
                status_code=409,
                detail="This tenant already has an agreement covering those dates.",
            )

        check = room_availability(
            db, room, form.start_date, form.end_date, exclude_tenant_id=tenant_id
        )
        if not check["is_available"]:
            raise HTTPException(409, check["availability_reason"])

        return db.execute(
            """
            INSERT INTO public.rental_agreements (
                tenant_id, property_id, room_id, start_date, end_date,
                monthly_rent, security_deposit
            )
            VALUES (%s, %s, %s, %s, %s, %s, %s)
            RETURNING agreement_id, tenant_id, property_id, room_id,
                      start_date, end_date, monthly_rent, security_deposit,
                      agreement_status
            """,
            (
                tenant_id,
                property_id,
                room_id,
                form.start_date,
                form.end_date,
                tenant["monthly_rate"],
                form.security_deposit,
            ),
        ).fetchone()


class RentBillInput(BaseModel):
    billing_period: date
    due_date: date


@app.get(
    "/owner/properties/{property_id}/rooms/{room_id}/tenants/{tenant_id}/agreements"
)
def list_owner_rental_agreements(
    property_id: int, room_id: int, tenant_id: int, request: Request
):
    with connect() as db:
        owner_id = require_property_owner(db, request)
        return db.execute(
            """
            SELECT a.agreement_id, a.start_date, a.end_date,
                   a.monthly_rent, a.agreement_status
            FROM public.rental_agreements AS a
            JOIN public.properties AS p ON p.property_id = a.property_id
            WHERE a.property_id = %s
              AND a.room_id = %s
              AND a.tenant_id = %s
              AND p.owner_id = %s
            ORDER BY a.start_date DESC, a.agreement_id DESC
            """,
            (property_id, room_id, tenant_id, owner_id),
        ).fetchall()


@app.post("/owner/agreements/{agreement_id}/bills", status_code=201)
def create_owner_rent_bill(
    agreement_id: int, form: RentBillInput, request: Request
):
    month = form.billing_period.replace(day=1)

    with connect() as db:
        owner_id = require_property_owner(db, request)
        agreement = db.execute(
            """
            SELECT a.tenant_id, a.monthly_rent, a.agreement_status,
                   a.start_date, a.end_date
            FROM public.rental_agreements AS a
            JOIN public.properties AS p ON p.property_id = a.property_id
            WHERE a.agreement_id = %s AND p.owner_id = %s
            FOR UPDATE OF a
            """,
            (agreement_id, owner_id),
        ).fetchone()

        if agreement is None:
            raise HTTPException(status_code=404, detail="Agreement not found.")

        if agreement["agreement_status"] not in ("pending", "active"):
            raise HTTPException(
                status_code=409,
                detail="Only pending or active agreements can be billed.",
            )

        start = agreement["start_date"]
        end = agreement["end_date"]
        if month < start.replace(day=1) or (
            end is not None and month > end.replace(day=1)
        ):
            raise HTTPException(
                status_code=422,
                detail="Choose a billing month covered by the agreement.",
            )

        existing = db.execute(
            """
            SELECT bill_id
            FROM public.rental_bills
            WHERE agreement_id = %s
              AND billing_period >= %s
              AND billing_period < %s::date + INTERVAL '1 month'
            LIMIT 1
            """,
            (agreement_id, month, month),
        ).fetchone()

        if existing is not None:
            raise HTTPException(
                status_code=409,
                detail="A rent bill already exists for this month.",
            )

        row = db.execute(
            """
            INSERT INTO public.rental_bills (
                agreement_id, billing_period, amount_due, due_date
            )
            VALUES (%s, %s, %s, %s)
            RETURNING bill_id, agreement_id, billing_period,
                      amount_due, due_date, bill_status
            """,
            (agreement_id, month, agreement["monthly_rent"], form.due_date),
        ).fetchone()
        notify_tenant(db, agreement["tenant_id"], f"bill:{row['bill_id']}", "New rent bill",
                      f"Bill #{row['bill_id']} is due {form.due_date}.", "bill")
        _owner_log(db, owner_id, f"Created rent bill #{row['bill_id']}")
        return row


@app.get("/owner/properties/{property_id}/rooms/{room_id}/tenants/{tenant_id}/bills")
def list_owner_rent_bills(
    property_id: int, room_id: int, tenant_id: int, request: Request
):
    with connect() as db:
        owner_id = require_property_owner(db, request)
        return db.execute(
            """
            SELECT b.bill_id, b.agreement_id, b.billing_period,
                   b.amount_due, b.due_date, b.bill_status,
                   GREATEST(
                       b.amount_due + COALESCE(b.late_fee, 0) - COALESCE((
                           SELECT SUM(pay.amount_paid)
                           FROM public.payments AS pay
                           WHERE pay.bill_id = b.bill_id
                             AND pay.payment_status = 'completed'
                       ), 0), 0
                   ) AS remaining_balance,
                   COALESCE((
                       SELECT jsonb_agg(
                           jsonb_build_object(
                               'payment_id', pay.payment_id,
                               'amount_paid', pay.amount_paid::text,
                               'payment_method', pay.payment_method,
                               'payment_date', pay.payment_date
                           )
                           ORDER BY pay.payment_date DESC NULLS LAST, pay.payment_id DESC
                       )
                       FROM public.payments AS pay
                       WHERE pay.bill_id = b.bill_id
                         AND pay.payment_status = 'completed'
                   ), '[]'::jsonb) AS payment_history
            FROM public.rental_bills AS b
            JOIN public.rental_agreements AS a
                ON a.agreement_id = b.agreement_id
            JOIN public.rooms AS r
                ON r.room_id = a.room_id AND r.property_id = a.property_id
            JOIN public.properties AS p
                ON p.property_id = r.property_id
            WHERE p.owner_id = %s
              AND p.property_id = %s
              AND r.room_id = %s
              AND a.tenant_id = %s
            ORDER BY b.billing_period DESC, b.bill_id DESC
            """,
            (owner_id, property_id, room_id, tenant_id),
        ).fetchall()


class RecordPaymentInput(BaseModel):
    expected_balance: Decimal = Field(gt=0, decimal_places=2, allow_inf_nan=False)
    amount_paid: Decimal = Field(
        gt=0, max_digits=10, decimal_places=2, allow_inf_nan=False
    )
    payment_method: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=50)
    ]
    transaction_reference: Annotated[
        str, StringConstraints(strip_whitespace=True, max_length=100)
    ] | None = None
    remarks: str | None = Field(default=None, max_length=1000)


@app.post("/owner/bills/{bill_id}/payments", status_code=201)
def record_owner_payment(bill_id: int, form: RecordPaymentInput, request: Request):
    with connect() as db:
        owner_id = require_property_owner(db, request)
        bill = db.execute(
            """
            SELECT b.bill_status, b.amount_due + COALESCE(b.late_fee, 0) AS total_due,
                   a.tenant_id
            FROM public.rental_bills AS b
            JOIN public.rental_agreements AS a ON a.agreement_id = b.agreement_id
            JOIN public.rooms AS r ON r.room_id = a.room_id
                AND r.property_id = a.property_id
            JOIN public.properties AS p ON p.property_id = r.property_id
            WHERE b.bill_id = %s AND p.owner_id = %s
            FOR UPDATE OF b
            """,
            (bill_id, owner_id),
        ).fetchone()
        if bill is None:
            raise HTTPException(status_code=404, detail="Bill not found.")
        if bill["bill_status"] != "unpaid":
            raise HTTPException(status_code=409, detail="This bill cannot accept payments.")

        existing = db.execute(
            """
            SELECT COALESCE(SUM(amount_paid), 0) AS total_paid
            FROM public.payments
            WHERE bill_id = %s AND payment_status = 'completed'
            """,
            (bill_id,),
        ).fetchone()
        balance = bill["total_due"] - existing["total_paid"]
        if form.expected_balance != balance:
            raise HTTPException(
                status_code=409, detail="Balance changed. Close this form to refresh the bills."
            )
        if form.amount_paid > balance:
            raise HTTPException(
                status_code=409, detail="Payment exceeds the remaining balance."
            )

        if form.transaction_reference and db.execute(
            """
            SELECT 1 FROM public.payments WHERE bill_id = %s
              AND payment_status = 'completed' AND lower(transaction_reference) = lower(%s)
            """, (bill_id, form.transaction_reference),
        ).fetchone():
            raise HTTPException(409, "This payment reference was already recorded.")

        payment = db.execute(
            """
            INSERT INTO public.payments (
                bill_id, tenant_id, amount_paid, payment_method,
                transaction_reference, remarks, payment_status
            )
            VALUES (%s, %s, %s, %s, %s, %s, 'completed')
            RETURNING payment_id, bill_id, amount_paid, payment_method,
                      transaction_reference, remarks, payment_status, payment_date
            """,
            (
                bill_id, bill["tenant_id"], form.amount_paid, form.payment_method,
                form.transaction_reference or None, form.remarks,
            ),
        ).fetchone()
        remaining = balance - form.amount_paid
        if remaining == 0:
            db.execute(
                "UPDATE public.rental_bills SET bill_status = 'paid' WHERE bill_id = %s",
                (bill_id,),
            )
        receipt_for_payment(db, payment["payment_id"])
        notify_tenant(db, bill["tenant_id"], f"payment:{payment['payment_id']}", "Payment recorded",
                      f"A payment was recorded for bill #{bill_id}.", "payment")
        _owner_log(db, owner_id, f"Recorded payment #{payment['payment_id']} for bill #{bill_id}")
        return {
            **payment,
            "remaining_balance": remaining,
            "bill_status": "paid" if remaining == 0 else "unpaid",
        }


class ReservationInput(BaseModel):
    preferred_move_in_date: date
    message: Annotated[
        str, StringConstraints(strip_whitespace=True, max_length=1000)
    ] = ""


@app.post(
    "/owner/properties/{property_id}/rooms/{room_id}/tenants/{tenant_id}/reservations",
    status_code=201,
)
def create_owner_reservation(
    property_id: int,
    room_id: int,
    tenant_id: int,
    form: ReservationInput,
    request: Request,
):
    with connect() as db:
        owner_id = require_property_owner(db, request)
        room = lock_property_room(db, property_id, room_id, owner_id=owner_id)
        tenant = db.execute(
            """
            SELECT t.tenant_id, t.room_id, t.tenant_status, CURRENT_DATE AS today
            FROM public.tenants AS t
            JOIN public.rooms AS r ON r.room_id = t.room_id
            JOIN public.properties AS p ON p.property_id = r.property_id
            WHERE t.tenant_id = %s
              AND r.room_id = %s
              AND p.property_id = %s
              AND p.owner_id = %s
            FOR UPDATE OF t
            """,
            (tenant_id, room_id, property_id, owner_id),
        ).fetchone()
        if tenant is None:
            raise HTTPException(status_code=404, detail="Tenant not found in this room.")

        if form.preferred_move_in_date < tenant["today"]:
            raise HTTPException(
                status_code=422, detail="Choose today or a future move-in date."
            )

        validate_reservation_slot(db, room, tenant, form.preferred_move_in_date, None)
        existing = db.execute(
            """
            SELECT reservation_id
            FROM public.reservations
            WHERE tenant_id = %s
              AND property_id = %s
              AND room_id = %s
              AND preferred_move_in_date = %s
              AND reservation_status = 'pending'
            LIMIT 1
            """,
            (tenant_id, property_id, room_id, form.preferred_move_in_date),
        ).fetchone()
        if existing is not None:
            raise HTTPException(
                status_code=409, detail="A pending reservation already exists for this date."
            )

        row = db.execute(
            """
            INSERT INTO public.reservations (
                tenant_id, property_id, room_id, preferred_move_in_date,
                reservation_status, message
            )
            VALUES (%s, %s, %s, %s, 'pending', %s)
            RETURNING reservation_id, tenant_id, property_id, room_id,
                      reservation_date, preferred_move_in_date, reservation_status, message
            """,
            (
                tenant_id,
                property_id,
                room_id,
                form.preferred_move_in_date,
                form.message or None,
            ),
        ).fetchone()
        _owner_log(db, owner_id, f"Created reservation #{row['reservation_id']}")
        return row


@app.get(
    "/owner/properties/{property_id}/rooms/{room_id}/tenants/{tenant_id}/reservations"
)
def list_owner_reservations(
    property_id: int, room_id: int, tenant_id: int, request: Request
):
    with connect() as db:
        owner_id = require_property_owner(db, request)
        return db.execute(
            """
            SELECT res.reservation_id, res.reservation_date,
                   res.preferred_move_in_date, res.reservation_status, res.message
            FROM public.reservations AS res
            JOIN public.rooms AS r
                ON r.room_id = res.room_id AND r.property_id = res.property_id
            JOIN public.properties AS p ON p.property_id = r.property_id
            WHERE p.owner_id = %s
              AND res.property_id = %s
              AND res.room_id = %s
              AND res.tenant_id = %s
            ORDER BY res.created_at DESC NULLS LAST, res.reservation_id DESC
            """,
            (owner_id, property_id, room_id, tenant_id),
        ).fetchall()


def _owner_log(db, owner_id: int, action: str):
    db.execute(
        "INSERT INTO public.activity_logs (user_id, action) VALUES (%s, %s)",
        (owner_id, action),
    )


class ReservationDecision(BaseModel):
    status: Literal["approved", "rejected", "cancelled"]


@app.put("/owner/reservations/{reservation_id}/status")
def set_owner_reservation_status(
    reservation_id: int, form: ReservationDecision, request: Request
):
    with connect() as db:
        owner_id = require_property_owner(db, request)
        reservation = db.execute(
            """
            SELECT res.*
            FROM public.reservations AS res
            JOIN public.properties AS p ON p.property_id = res.property_id
            WHERE p.owner_id = %s AND res.reservation_id = %s
            FOR UPDATE OF res
            """, (owner_id, reservation_id),
        ).fetchone()
        if reservation is None:
            raise HTTPException(404, "Reservation not found.")
        if reservation["reservation_status"] != "pending":
            raise HTTPException(409, "This reservation has already been decided.")

        agreement_id = None
        if form.status == "approved":
            room = lock_property_room(
                db, reservation["property_id"], reservation["room_id"], owner_id=owner_id
            )
            tenant = db.execute(
                "SELECT tenant_id, user_id, room_id, tenant_status FROM public.tenants "
                "WHERE tenant_id = %s FOR UPDATE", (reservation["tenant_id"],),
            ).fetchone()
            if tenant is None:
                raise HTTPException(409, "Assign a tenant before approving this reservation.")
            start = reservation["preferred_move_in_date"]
            end = reservation["requested_end_date"]
            if start is None or (end is not None and end < start):
                raise HTTPException(409, "This reservation needs a valid move-in date.")
            validate_reservation_slot(db, room, tenant, start, end)
            agreement_id = db.execute(
                """
                INSERT INTO public.rental_agreements
                    (tenant_id, property_id, room_id, start_date, end_date,
                     monthly_rent, agreement_status)
                VALUES (%s, %s, %s, %s, %s, %s, 'pending')
                RETURNING agreement_id
                """,
                (tenant["tenant_id"], room["property_id"], room["room_id"],
                 start, end, room["monthly_rate"]),
            ).fetchone()["agreement_id"]

        row = db.execute(
            """
            UPDATE public.reservations
            SET reservation_status = %s, agreement_id = %s
            WHERE reservation_id = %s
            RETURNING reservation_id, reservation_status, agreement_id
            """, (form.status, agreement_id, reservation_id),
        ).fetchone()
        _owner_log(db, owner_id, f"{form.status.capitalize()} reservation #{reservation_id}")
        db.execute(
            """
            INSERT INTO public.notifications (user_id, title, message, notification_type)
            SELECT user_id, %s, %s, 'reservation' FROM public.tenants
            WHERE tenant_id = %s AND user_id IS NOT NULL
            """,
            ("Reservation updated", f"Reservation #{reservation_id} was {form.status}.",
             reservation["tenant_id"]),
        )
        return row


class MaintenanceInput(BaseModel):
    title: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=150)
    ]
    description: Annotated[
        str, StringConstraints(strip_whitespace=True, min_length=1, max_length=3000)
    ]
    priority: Literal["normal", "urgent"] = "normal"


class MaintenanceStatus(BaseModel):
    status: Literal["in_progress", "resolved"]


@app.get("/owner/properties/{property_id}/rooms/{room_id}/maintenance")
def list_owner_maintenance(property_id: int, room_id: int, request: Request):
    with connect() as db:
        owner_id = require_property_owner(db, request)
        return db.execute(
            """
            SELECT m.request_id, m.issue_title, m.issue_description, m.priority,
                   m.request_status, m.submitted_at, m.resolved_at
            FROM public.maintenance_requests AS m
            JOIN public.rooms AS r ON r.room_id = m.room_id
            JOIN public.properties AS p ON p.property_id = r.property_id
            WHERE p.owner_id = %s AND p.property_id = %s AND r.room_id = %s
            ORDER BY m.submitted_at DESC NULLS LAST, m.request_id DESC
            """,
            (owner_id, property_id, room_id),
        ).fetchall()


@app.post("/owner/properties/{property_id}/rooms/{room_id}/maintenance", status_code=201)
def create_owner_maintenance(
    property_id: int, room_id: int, form: MaintenanceInput, request: Request
):
    with connect() as db:
        owner_id = require_property_owner(db, request)
        row = db.execute(
            """
            INSERT INTO public.maintenance_requests
                (room_id, issue_title, issue_description, priority, request_status)
            SELECT r.room_id, %s, %s, %s, 'pending'
            FROM public.rooms AS r
            JOIN public.properties AS p ON p.property_id = r.property_id
            WHERE p.owner_id = %s AND p.property_id = %s AND r.room_id = %s
            RETURNING request_id, request_status
            """,
            (form.title, form.description, form.priority, owner_id, property_id, room_id),
        ).fetchone()
        if row is None:
            raise HTTPException(404, "Room not found.")
        _owner_log(db, owner_id, f"Created maintenance request #{row['request_id']}")
        return row


@app.put("/owner/maintenance/{request_id}/status")
def set_owner_maintenance_status(request_id: int, form: MaintenanceStatus, request: Request):
    previous = {"in_progress": "pending", "resolved": "in_progress"}[form.status]
    with connect() as db:
        owner_id = require_property_owner(db, request)
        row = db.execute(
            """
            UPDATE public.maintenance_requests AS m
            SET request_status = %s,
                resolved_at = CASE WHEN %s = 'resolved' THEN CURRENT_TIMESTAMP ELSE NULL END
            FROM public.rooms AS r
            JOIN public.properties AS p ON p.property_id = r.property_id
            WHERE m.room_id = r.room_id AND p.owner_id = %s
              AND m.request_id = %s AND m.request_status = %s
            RETURNING m.request_id, m.request_status, m.tenant_id
            """,
            (form.status, form.status, owner_id, request_id, previous),
        ).fetchone()
        if row is None:
            raise HTTPException(409, "This maintenance request has changed or is unavailable.")
        _owner_log(db, owner_id, f"Updated maintenance request #{request_id} to {form.status}")
        if row["tenant_id"] is not None:
            notify_tenant(db, row["tenant_id"], f"maintenance:{request_id}:{form.status}",
                          "Maintenance updated", f"Request #{request_id}: {form.status}.", "maintenance")
        return row


@app.get("/owner/activity")
def owner_activity(request: Request):
    with connect() as db:
        owner_id = require_property_owner(db, request)
        return db.execute(
            """
            SELECT log_id, action, created_at
            FROM public.activity_logs
            WHERE user_id = %s
            ORDER BY created_at DESC NULLS LAST, log_id DESC
            LIMIT 100
            """,
            (owner_id,),
        ).fetchall()


@app.get("/owner/rent-reminders")
def owner_rent_reminders(request: Request):
    with connect() as db:
        owner_id = require_property_owner(db, request)
        return db.execute(
            """
            SELECT b.bill_id, b.due_date, t.full_name, p.property_name, r.room_number,
                   b.amount_due + COALESCE(b.late_fee, 0) - COALESCE(paid.total, 0)
                       AS remaining_balance,
                   b.due_date < CURRENT_DATE AS overdue
            FROM public.rental_bills AS b
            JOIN public.rental_agreements AS a ON a.agreement_id = b.agreement_id
            JOIN public.tenants AS t ON t.tenant_id = a.tenant_id
            JOIN public.rooms AS r ON r.room_id = a.room_id AND r.property_id = a.property_id
            JOIN public.properties AS p ON p.property_id = r.property_id
            LEFT JOIN LATERAL (
                SELECT SUM(amount_paid) AS total
                FROM public.payments
                WHERE bill_id = b.bill_id AND payment_status = 'completed'
            ) AS paid ON TRUE
            WHERE p.owner_id = %s AND b.bill_status = 'unpaid'
              AND b.due_date <= CURRENT_DATE + 7
              AND b.amount_due + COALESCE(b.late_fee, 0) > COALESCE(paid.total, 0)
            ORDER BY b.due_date, b.bill_id
            """,
            (owner_id,),
        ).fetchall()


@app.get("/owner/subscriptions")
def owner_subscriptions(request: Request):
    with connect() as db:
        owner_id = require_property_owner(db, request)
        return {
            "plans": db.execute(
                """
                SELECT plan_id, plan_name, description, price, duration_days, property_limit
                FROM public.subscription_plans
                WHERE plan_status = 'active'
                ORDER BY price, plan_id
                """
            ).fetchall(),
            "subscriptions": db.execute(
                """
                SELECT s.subscription_id, p.plan_name, s.start_date, s.end_date,
                       s.subscription_status, s.payment_status
                FROM public.owner_subscriptions AS s
                LEFT JOIN public.subscription_plans AS p ON p.plan_id = s.plan_id
                WHERE s.owner_id = %s
                ORDER BY s.end_date DESC, s.subscription_id DESC
                """,
                (owner_id,),
            ).fetchall(),
        }


def availability_dates(db, start, end):
    if start is None:
        start = db.execute("SELECT CURRENT_DATE AS today").fetchone()["today"]
    end = end or start
    if end < start:
        raise HTTPException(422, "End date must be on or after the start date.")
    return start, end


def rooms_with_availability(db, property_id, start, end):
    rooms = db.execute(
        """
        SELECT room_id, room_number, room_type, capacity, monthly_rate, room_status
        FROM public.rooms WHERE property_id = %s ORDER BY room_number, room_id
        """, (property_id,),
    ).fetchall()
    return [{**room, **room_availability(db, room, start, end)} for room in rooms]


def lock_property_room(db, property_id, room_id, *, owner_id=None):
    room = db.execute(
        """
        SELECT r.room_id, r.property_id, r.capacity, r.room_status, r.monthly_rate
        FROM public.rooms AS r
        JOIN public.properties AS p ON p.property_id = r.property_id
        WHERE r.property_id = %(property)s AND r.room_id = %(room)s
          AND (%(owner)s::integer IS NULL OR p.owner_id = %(owner)s)
        FOR UPDATE OF r
        """, {"property": property_id, "room": room_id, "owner": owner_id},
    ).fetchone()
    if room is None:
        raise HTTPException(404, "Room not found.")
    return room


def validate_reservation_slot(db, room, tenant, start, end):
    tenant_id = tenant["tenant_id"]
    if (tenant["room_id"] not in (None, room["room_id"])
            and tenant["tenant_status"] in (None, "active")):
        raise HTTPException(409, "This tenant is currently assigned to another room.")
    conflict = db.execute(
        """
        SELECT 1 FROM public.rental_agreements
        WHERE tenant_id = %(tenant)s AND agreement_status IN ('pending', 'active')
          AND (end_date IS NULL OR end_date >= %(start)s)
          AND (%(end)s::date IS NULL OR start_date <= %(end)s)
        UNION ALL
        SELECT 1 FROM public.reservations
        WHERE tenant_id = %(tenant)s AND agreement_id IS NULL
          AND reservation_status IN ('approved', 'confirmed')
          AND (requested_end_date IS NULL OR requested_end_date >= %(start)s)
          AND (%(end)s::date IS NULL OR
               COALESCE(preferred_move_in_date, reservation_date, CURRENT_DATE) <= %(end)s)
        LIMIT 1
        """, {"tenant": tenant_id, "start": start, "end": end},
    ).fetchone()
    if conflict:
        raise HTTPException(409, "This tenant already has a booking covering those dates.")
    availability = room_availability(
        db, room, start, end, exclude_tenant_id=tenant_id,
    )
    if not availability["is_available"]:
        raise HTTPException(409, availability["availability_reason"])


def public_property(db, property_id):
    row = db.execute(
        """
        SELECT p.property_id, p.property_name, p.address, p.description
        FROM public.properties AS p JOIN public.boardease_listing_status AS s USING (property_id)
        WHERE p.property_id = %s AND s.verified AND s.published AND NOT s.archived
        """, (property_id,),
    ).fetchone()
    if row is None:
        raise HTTPException(404, "Property not found.")
    return row


@app.get("/properties/{property_id}/rooms")
def public_rooms(property_id: int, start_date: date | None = None, end_date: date | None = None):
    with connect() as db:
        listing = public_property(db, property_id)
        start, end = availability_dates(db, start_date, end_date)
        amenities = db.execute(
            """
            SELECT amenity_name FROM public.amenities
            WHERE property_id = %s AND availability_status IS TRUE ORDER BY amenity_name
            """, (property_id,),
        ).fetchall()
        rooms = rooms_with_availability(db, property_id, start, end)
        room_images = db.execute(
            """
            SELECT DISTINCT ON (i.room_id) i.room_id, i.image_url
            FROM public.room_images i JOIN public.rooms r USING (room_id)
            WHERE r.property_id = %s AND i.image_url ~ '^https?://'
            ORDER BY i.room_id, i.is_primary DESC NULLS LAST, i.image_id
            """, (property_id,),
        ).fetchall()
        image_by_room = {row["room_id"]: row["image_url"] for row in room_images}
        rules = db.execute(
            """
            SELECT rule_title, rule_description FROM public.property_rules
            WHERE property_id = %s AND rule_status = 'active' ORDER BY rule_id
            """, (property_id,),
        ).fetchall()
        reviews = db.execute(
            """
            SELECT rating, review_comment FROM public.reviews
            WHERE property_id = %s AND review_status = 'published'
            ORDER BY review_id DESC LIMIT 30
            """, (property_id,),
        ).fetchall()
        return {
            "property": listing,
            "amenities": [row["amenity_name"] for row in amenities],
            "rules": rules,
            "reviews": reviews,
            "rooms": [
                {**{key: value for key, value in room.items() if key != "occupied_spaces"},
                 "image_url": image_by_room.get(room["room_id"])}
                for room in rooms
            ],
        }


@app.get("/owner/properties/{property_id}/rooms/{room_id}/reservations")
def owner_room_reservations(property_id: int, room_id: int, request: Request):
    with connect() as db:
        owner_id = require_property_owner(db, request)
        return db.execute(
            """
            SELECT res.reservation_id, res.preferred_move_in_date, res.requested_end_date,
                   res.reservation_status, res.agreement_id, a.agreement_status, t.full_name
            FROM public.reservations AS res
            JOIN public.properties AS p ON p.property_id = res.property_id
            LEFT JOIN public.tenants AS t ON t.tenant_id = res.tenant_id
            LEFT JOIN public.rental_agreements AS a ON a.agreement_id = res.agreement_id
            WHERE p.owner_id = %s AND res.property_id = %s AND res.room_id = %s
            ORDER BY res.reservation_id DESC
            """, (owner_id, property_id, room_id),
        ).fetchall()


class BoarderReservationInput(BaseModel):
    start_date: date
    end_date: date
    message: Annotated[str, StringConstraints(strip_whitespace=True, max_length=1000)] = ""

    @model_validator(mode="after")
    def validate_dates(self):
        if self.end_date < self.start_date:
            raise ValueError("End date must be on or after the start date.")
        return self


def lock_boarder(db, user_id):
    user = db.execute(
        "SELECT user_id, full_name, email FROM public.users WHERE user_id = %s FOR UPDATE",
        (user_id,),
    ).fetchone()
    tenant = db.execute(
        "SELECT tenant_id, room_id, tenant_status FROM public.tenants "
        "WHERE user_id = %s FOR UPDATE", (user_id,),
    ).fetchone()
    if tenant is None:
        tenant = db.execute(
            """
            INSERT INTO public.tenants (user_id, full_name, email)
            VALUES (%s, %s, %s)
            RETURNING tenant_id, room_id, tenant_status
            """, (user_id, user["full_name"], user["email"]),
        ).fetchone()
    return tenant


@app.post("/tenant/properties/{property_id}/rooms/{room_id}/reservations", status_code=201)
def request_boarder_reservation(
    property_id: int, room_id: int, form: BoarderReservationInput, request: Request
):
    with connect() as db:
        user_id = require_role(db, request, "tenant")
        public_property(db, property_id)
        room = lock_property_room(db, property_id, room_id)
        public_property(db, property_id)
        tenant = lock_boarder(db, user_id)
        today = db.execute("SELECT CURRENT_DATE AS today").fetchone()["today"]
        if form.start_date < today:
            raise HTTPException(422, "Choose today or a future move-in date.")
        validate_reservation_slot(db, room, tenant, form.start_date, form.end_date)
        if db.execute(
            """
            SELECT 1 FROM public.reservations
            WHERE tenant_id = %s AND reservation_status = 'pending'
              AND preferred_move_in_date <= %s
              AND (requested_end_date IS NULL OR requested_end_date >= %s)
            LIMIT 1
            """, (tenant["tenant_id"], form.end_date, form.start_date),
        ).fetchone():
            raise HTTPException(409, "You already have a pending request for those dates.")
        row = db.execute(
            """
            INSERT INTO public.reservations
                (tenant_id, property_id, room_id, preferred_move_in_date,
                 requested_end_date, reservation_status, message)
            VALUES (%s, %s, %s, %s, %s, 'pending', %s)
            RETURNING reservation_id, reservation_status
            """, (tenant["tenant_id"], property_id, room_id, form.start_date, form.end_date,
                  form.message or None),
        ).fetchone()
        db.execute(
            """
            INSERT INTO public.notifications (user_id, title, message, notification_type)
            SELECT owner_id, 'New reservation request', %s, 'reservation'
            FROM public.properties WHERE property_id = %s AND owner_id IS NOT NULL
            """, (f"Reservation #{row['reservation_id']} is ready for review.", property_id),
        )
        return row


@app.get("/tenant/reservations")
def boarder_reservations(request: Request):
    with connect() as db:
        user_id = require_role(db, request, "tenant")
        return db.execute(
            """
            SELECT res.reservation_id, res.preferred_move_in_date, res.requested_end_date,
                   res.reservation_status, res.agreement_id, p.property_name, r.room_number
            FROM public.reservations AS res
            JOIN public.tenants AS t ON t.tenant_id = res.tenant_id
            JOIN public.properties AS p ON p.property_id = res.property_id
            JOIN public.rooms AS r ON r.room_id = res.room_id AND r.property_id = p.property_id
            WHERE t.user_id = %s ORDER BY res.reservation_id DESC
            """, (user_id,),
        ).fetchall()


@app.put("/owner/properties/{property_id}")
def edit_owner_property(property_id: int, form: PropertyInput, request: Request):
    with connect() as db:
        owner_id = require_property_owner(db, request)
        row = db.execute(
            """
            UPDATE public.properties SET property_name = %s, address = %s, description = %s
            WHERE property_id = %s AND owner_id = %s
            RETURNING property_id, property_name, address, description
            """, (form.property_name, form.address, form.description or None, property_id, owner_id),
        ).fetchone()
        if row is None:
            raise HTTPException(404, "Property not found.")
        _owner_log(db, owner_id, f"Updated property #{property_id}")
        return row


class ListingAction(BaseModel):
    action: Literal["publish", "unpublish", "archive"]


@app.put("/owner/properties/{property_id}/listing")
def change_property_listing(property_id: int, form: ListingAction, request: Request):
    with connect() as db:
        owner_id = require_property_owner(db, request)
        if db.execute(
            "SELECT 1 FROM public.properties WHERE property_id = %s AND owner_id = %s FOR UPDATE",
            (property_id, owner_id),
        ).fetchone() is None:
            raise HTTPException(404, "Property not found.")
        db.execute(
            "INSERT INTO public.boardease_listing_status (property_id) VALUES (%s) ON CONFLICT DO NOTHING",
            (property_id,),
        )
        state = db.execute(
            "SELECT verified, archived FROM public.boardease_listing_status WHERE property_id = %s FOR UPDATE",
            (property_id,),
        ).fetchone()
        if form.action == "publish" and (not state["verified"] or state["archived"]):
            raise HTTPException(409, "Only verified, non-archived properties can be published.")
        row = db.execute(
            """
            UPDATE public.boardease_listing_status SET published = %s, archived = archived OR %s
            WHERE property_id = %s RETURNING verified, published, archived
            """, (form.action == "publish", form.action == "archive", property_id),
        ).fetchone()
        _owner_log(db, owner_id, f"Property #{property_id}: {form.action}")
        return row


def notify_tenant(db, tenant_id, event_key, title, message, category):
    db.execute(
        """
        INSERT INTO public.notifications (user_id, event_key, title, message, notification_type)
        SELECT user_id, %s, %s, %s, %s FROM public.tenants
        WHERE tenant_id = %s AND user_id IS NOT NULL
        ON CONFLICT (user_id, event_key) DO NOTHING
        """, (event_key, title, message, category, tenant_id),
    )


def receipt_for_payment(db, payment_id):
    return db.execute(
        """
        INSERT INTO public.payment_receipts (payment_id, receipt_number)
        VALUES (%s, %s)
        ON CONFLICT (receipt_number) DO UPDATE SET receipt_number = EXCLUDED.receipt_number
        RETURNING receipt_id, receipt_number, issued_at
        """, (payment_id, f"BE-PAY-{payment_id}"),
    ).fetchone()


def completed_balance(db, bill_id, total_due):
    paid = db.execute(
        """
        SELECT COALESCE(SUM(amount_paid), 0) AS paid
        FROM public.payments WHERE bill_id = %s AND payment_status = 'completed'
        """, (bill_id,),
    ).fetchone()["paid"]
    return total_due - paid


@app.get("/tenant/bills")
def boarder_bills(request: Request):
    with connect() as db:
        user_id = require_role(db, request, "tenant")
        bills = db.execute(
            """
            SELECT b.bill_id, b.billing_period, b.amount_due, b.late_fee, b.due_date,
                   b.bill_status, p.property_name, r.room_number
            FROM public.rental_bills b
            JOIN public.rental_agreements a ON a.agreement_id = b.agreement_id
            JOIN public.tenants t ON t.tenant_id = a.tenant_id
            JOIN public.rooms r ON r.room_id = a.room_id AND r.property_id = a.property_id
            JOIN public.properties p ON p.property_id = r.property_id
            WHERE t.user_id = %s ORDER BY b.due_date DESC, b.bill_id DESC
            """, (user_id,),
        ).fetchall()
        for bill in bills:
            bill["payments"] = db.execute(
                """
                SELECT pay.payment_id, pay.amount_paid, pay.payment_status, pay.payment_method,
                       pay.transaction_reference, pay.payment_date,
                       receipt.receipt_number, receipt.issued_at
                FROM public.payments pay
                LEFT JOIN LATERAL (
                    SELECT receipt_number, issued_at FROM public.payment_receipts
                    WHERE payment_id = pay.payment_id ORDER BY receipt_id DESC LIMIT 1
                ) receipt ON TRUE
                WHERE pay.bill_id = %s ORDER BY pay.payment_id DESC
                """, (bill["bill_id"],),
            ).fetchall()
            paid = sum((r["amount_paid"] for r in bill["payments"] if r["payment_status"] == "completed"),
                       Decimal("0"))
            bill["remaining_balance"] = max(Decimal("0"), bill["amount_due"] +
                                            (bill["late_fee"] or Decimal("0")) - paid)
        return bills


class ManualProofInput(BaseModel):
    amount_paid: Decimal = Field(gt=0, max_digits=10, decimal_places=2, allow_inf_nan=False)
    method: Literal["cash", "gcash", "bank_transfer"]
    reference: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=100)]
    proof_url: AnyHttpUrl | None = None


@app.post("/tenant/bills/{bill_id}/payment-proofs", status_code=201)
def submit_manual_proof(bill_id: int, form: ManualProofInput, request: Request):
    with connect() as db:
        user_id = require_role(db, request, "tenant")
        bill = db.execute(
            """
            SELECT b.bill_status, b.amount_due + COALESCE(b.late_fee, 0) AS total_due,
                   a.tenant_id
            FROM public.rental_bills b
            JOIN public.rental_agreements a ON a.agreement_id = b.agreement_id
            JOIN public.tenants t ON t.tenant_id = a.tenant_id
            WHERE b.bill_id = %s AND t.user_id = %s FOR UPDATE OF b
            """, (bill_id, user_id),
        ).fetchone()
        if bill is None:
            raise HTTPException(404, "Bill not found.")
        if db.execute(
            """
            SELECT 1 FROM public.payments WHERE bill_id = %s
              AND lower(transaction_reference) = lower(%s)
              AND payment_status IN ('pending', 'completed')
            """, (bill_id, form.reference),
        ).fetchone():
            raise HTTPException(409, "This payment reference was already submitted.")
        if bill["bill_status"] != "unpaid" or form.amount_paid > completed_balance(
            db, bill_id, bill["total_due"]
        ):
            raise HTTPException(409, "The amount exceeds the bill's outstanding balance.")
        payment = db.execute(
            """
            INSERT INTO public.payments
                (bill_id, tenant_id, payment_method, amount_paid, transaction_reference,
                 payment_status, remarks)
            VALUES (%s, %s, %s, %s, %s, 'pending', 'Tenant-submitted manual proof')
            RETURNING payment_id, payment_status
            """, (bill_id, bill["tenant_id"], form.method, form.amount_paid, form.reference),
        ).fetchone()
        if form.proof_url is not None:
            db.execute(
                "INSERT INTO public.payment_proofs (payment_id, file_url) VALUES (%s, %s)",
                (payment["payment_id"], str(form.proof_url)),
            )
        return payment


@app.get("/owner/payment-proofs")
def pending_owner_proofs(request: Request):
    with connect() as db:
        owner_id = require_property_owner(db, request)
        return db.execute(
            """
            SELECT pay.payment_id, pay.bill_id, pay.amount_paid, pay.payment_method,
                   pay.transaction_reference, t.full_name, p.property_name,
                   proof.file_url AS proof_url
            FROM public.payments pay
            JOIN public.rental_bills b ON pay.bill_id = b.bill_id
            JOIN public.rental_agreements a ON a.agreement_id = b.agreement_id
            JOIN public.properties p ON p.property_id = a.property_id
            JOIN public.tenants t ON t.tenant_id = a.tenant_id
            LEFT JOIN LATERAL (
                SELECT file_url FROM public.payment_proofs
                WHERE payment_id = pay.payment_id ORDER BY proof_id DESC LIMIT 1
            ) proof ON TRUE
            WHERE p.owner_id = %s AND pay.payment_status = 'pending'
              AND pay.remarks = 'Tenant-submitted manual proof'
            ORDER BY pay.payment_id DESC
            """, (owner_id,),
        ).fetchall()


class ProofDecision(BaseModel):
    status: Literal["approved", "rejected"]


@app.put("/owner/payment-proofs/{payment_id}")
def decide_manual_proof(payment_id: int, form: ProofDecision, request: Request):
    with connect() as db:
        owner_id = require_property_owner(db, request)
        bill = db.execute(
            """
            SELECT b.bill_id, b.bill_status, b.amount_due + COALESCE(b.late_fee, 0) AS total_due,
                   a.tenant_id
            FROM public.payments pay
            JOIN public.rental_bills b ON pay.bill_id = b.bill_id
            JOIN public.rental_agreements a ON b.agreement_id = a.agreement_id
            JOIN public.properties p ON p.property_id = a.property_id
            WHERE pay.payment_id = %s AND p.owner_id = %s
              AND pay.remarks = 'Tenant-submitted manual proof'
            FOR UPDATE OF b
            """, (payment_id, owner_id),
        ).fetchone()
        if bill is None:
            raise HTTPException(404, "Payment submission not found.")
        payment = db.execute(
            "SELECT amount_paid, payment_status, transaction_reference FROM public.payments "
            "WHERE payment_id = %s FOR UPDATE", (payment_id,),
        ).fetchone()
        status = "completed" if form.status == "approved" else "rejected"
        if payment["payment_status"] == status:
            return {"payment_id": payment_id, "payment_status": status}
        if payment["payment_status"] != "pending":
            raise HTTPException(409, "This submission has already been decided.")
        if status == "completed":
            balance = completed_balance(db, bill["bill_id"], bill["total_due"])
            if bill["bill_status"] != "unpaid" or payment["amount_paid"] > balance:
                raise HTTPException(409, "The bill balance changed. Review this submission.")
            if db.execute(
                """
                SELECT 1 FROM public.payments WHERE bill_id = %s AND payment_status = 'completed'
                AND lower(transaction_reference) = lower(%s)
                """, (bill["bill_id"], payment["transaction_reference"]),
            ).fetchone():
                raise HTTPException(409, "This reference has already been recorded.")
            if payment["amount_paid"] == balance:
                db.execute("UPDATE public.rental_bills SET bill_status = 'paid' WHERE bill_id = %s",
                           (bill["bill_id"],))
            receipt_for_payment(db, payment_id)
        db.execute("UPDATE public.payments SET payment_status = %s WHERE payment_id = %s",
                   (status, payment_id))
        db.execute(
            """
            UPDATE public.payment_proofs
            SET verification_status = %s, verified_by = %s, verified_at = CURRENT_TIMESTAMP
            WHERE payment_id = %s
            """, (form.status, owner_id, payment_id),
        )
        _owner_log(db, owner_id, f"{form.status.capitalize()} manual payment #{payment_id}")
        notify_tenant(db, bill["tenant_id"], f"proof:{payment_id}:{status}", "Payment reviewed",
                      f"Payment submission #{payment_id} was {form.status}.", "payment")
        return {"payment_id": payment_id, "payment_status": status}


@app.get("/tenant/maintenance")
def tenant_maintenance(request: Request):
    with connect() as db:
        user_id = require_role(db, request, "tenant")
        return db.execute(
            """
            SELECT m.request_id, m.issue_title, m.issue_description, m.priority,
                   m.request_status, m.admin_remarks, m.submitted_at
            FROM public.maintenance_requests m JOIN public.tenants t USING (tenant_id)
            WHERE t.user_id = %s ORDER BY m.request_id DESC
            """, (user_id,),
        ).fetchall()


@app.post("/tenant/maintenance", status_code=201)
def submit_tenant_maintenance(form: MaintenanceInput, request: Request):
    with connect() as db:
        user_id = require_role(db, request, "tenant")
        row = db.execute(
            """
            INSERT INTO public.maintenance_requests
                (tenant_id, room_id, issue_title, issue_description, priority, request_status)
            SELECT tenant_id, room_id, %s, %s, %s, 'pending'
            FROM public.tenants WHERE user_id = %s AND room_id IS NOT NULL
              AND COALESCE(tenant_status, 'active') = 'active'
            RETURNING request_id, request_status
            """, (form.title, form.description, form.priority, user_id),
        ).fetchone()
        if row is None:
            raise HTTPException(409, "An active room assignment is required.")
        return row


@app.get("/account/notifications")
def account_notifications(request: Request):
    with connect() as db:
        user = profile_user(db, request)
        return db.execute(
            """
            SELECT notification_id, title, message, notification_type, is_read, created_at
            FROM public.notifications WHERE user_id = %s
              AND (scheduled_at IS NULL OR scheduled_at <= CURRENT_TIMESTAMP)
            ORDER BY created_at DESC NULLS LAST, notification_id DESC LIMIT 100
            """, (user["user_id"],),
        ).fetchall()


@app.put("/account/notifications/{notification_id}/read")
def read_notification(notification_id: int, request: Request):
    with connect() as db:
        user = profile_user(db, request)
        row = db.execute(
            """
            UPDATE public.notifications SET is_read = TRUE
            WHERE user_id = %s AND notification_id = %s
            RETURNING notification_id, is_read
            """, (user["user_id"], notification_id),
        ).fetchone()
        if row is None:
            raise HTTPException(404, "Notification not found.")
        return row


@app.post("/owner/rent-reminders/run")
def create_owner_rent_reminders(request: Request):
    with connect() as db:
        owner_id = require_property_owner(db, request)
        result = db.execute(
            """
            INSERT INTO public.notifications (user_id, event_key, title, message, notification_type)
            SELECT t.user_id, 'rent-due:' || b.bill_id || ':' || b.due_date,
                   'Rent due soon', 'Bill #' || b.bill_id || ' is due ' || b.due_date || '.', 'bill'
            FROM public.rental_bills b
            JOIN public.rental_agreements a ON a.agreement_id = b.agreement_id
            JOIN public.tenants t ON a.tenant_id = t.tenant_id
            JOIN public.properties p ON a.property_id = p.property_id
            WHERE p.owner_id = %s AND t.user_id IS NOT NULL AND b.bill_status = 'unpaid'
              AND b.due_date BETWEEN CURRENT_DATE AND CURRENT_DATE + 7
              AND b.amount_due + COALESCE(b.late_fee, 0) > COALESCE((
                  SELECT SUM(pay.amount_paid) FROM public.payments pay
                  WHERE pay.bill_id = b.bill_id AND pay.payment_status = 'completed'
              ), 0)
            ON CONFLICT (user_id, event_key) DO NOTHING
            """, (owner_id,),
        )
        return {"created": result.rowcount}


@app.put("/owner/reservations/{reservation_id}/move-in")
def move_in_reservation(reservation_id: int, request: Request):
    with connect() as db:
        owner_id = require_property_owner(db, request)
        res = db.execute(
            """
            SELECT res.* FROM public.reservations res
            JOIN public.properties p ON p.property_id = res.property_id
            WHERE res.reservation_id = %s AND p.owner_id = %s FOR UPDATE OF res
            """, (reservation_id, owner_id),
        ).fetchone()
        if res is None:
            raise HTTPException(404, "Reservation not found.")
        if res["reservation_status"] != "approved" or res["agreement_id"] is None:
            raise HTTPException(409, "An approved reservation with an agreement is required.")
        room = lock_property_room(db, res["property_id"], res["room_id"], owner_id=owner_id)
        tenant = db.execute(
            "SELECT tenant_id, room_id, tenant_status FROM public.tenants "
            "WHERE tenant_id = %s FOR UPDATE", (res["tenant_id"],),
        ).fetchone()
        agreement = db.execute(
            """
            SELECT agreement_status, start_date, end_date, CURRENT_DATE AS today
            FROM public.rental_agreements
            WHERE agreement_id = %s AND tenant_id = %s AND room_id = %s AND property_id = %s
            FOR UPDATE
            """, (res["agreement_id"], res["tenant_id"], room["room_id"], room["property_id"]),
        ).fetchone()
        if tenant is None or agreement is None or agreement["agreement_status"] != "pending":
            raise HTTPException(409, "A pending agreement is required for move-in.")
        today = agreement["today"]
        if today < agreement["start_date"] or (
            agreement["end_date"] is not None and today > agreement["end_date"]
        ):
            raise HTTPException(409, "Move-in is only available during the agreement dates.")
        if (tenant["room_id"] not in (None, room["room_id"])
                and tenant["tenant_status"] in (None, "active")):
            raise HTTPException(409, "This tenant is currently assigned to another room.")
        slot = room_availability(db, room, today, agreement["end_date"],
                                 exclude_tenant_id=res["tenant_id"])
        if not slot["is_available"]:
            raise HTTPException(409, slot["availability_reason"])
        db.execute("UPDATE public.rental_agreements SET agreement_status = 'active' WHERE agreement_id = %s",
                   (res["agreement_id"],))
        db.execute(
            "UPDATE public.tenants SET room_id = %s, move_in_date = %s, tenant_status = 'active' "
            "WHERE tenant_id = %s", (room["room_id"], today, res["tenant_id"]),
        )
        db.execute(
            """
            INSERT INTO public.tenant_movements
                (tenant_id, room_id, movement_type, movement_date, recorded_by)
            VALUES (%s, %s, 'move_in', %s, %s)
            """, (res["tenant_id"], room["room_id"], today, owner_id),
        )
        _owner_log(db, owner_id, f"Moved in tenant for reservation #{reservation_id}")
        notify_tenant(db, res["tenant_id"], f"move-in:{reservation_id}", "Move-in recorded",
                      f"Your move-in for reservation #{reservation_id} was recorded.", "reservation")
        return {"reservation_id": reservation_id, "agreement_status": "active"}


@app.get("/owner/summary")
def owner_summary(request: Request):
    with connect() as db:
        owner_id = require_property_owner(db, request)
        return db.execute(
            """
            WITH properties AS (
                SELECT p.property_id FROM public.properties p
                LEFT JOIN public.boardease_listing_status s USING (property_id)
                WHERE p.owner_id = %s AND NOT COALESCE(s.archived, FALSE)
            ), rooms AS (
                SELECT r.room_id, r.capacity FROM public.rooms r JOIN properties p USING (property_id)
            ), bills AS (
                SELECT b.bill_id, b.bill_status FROM public.rental_bills b
                JOIN public.rental_agreements a ON a.agreement_id = b.agreement_id
                JOIN rooms r ON r.room_id = a.room_id
            )
            SELECT
                (SELECT count(*) FROM properties) AS properties,
                (SELECT count(*) FROM rooms) AS rooms,
                (SELECT COALESCE(sum(capacity), 0) FROM rooms) AS capacity,
                (SELECT count(*) FROM public.tenants t JOIN rooms r USING (room_id)
                 WHERE COALESCE(t.tenant_status, 'active') = 'active') AS tenants,
                (SELECT count(*) FROM public.reservations res JOIN rooms r USING (room_id)
                 WHERE res.reservation_status = 'pending') AS pending_reservations,
                (SELECT count(*) FROM public.maintenance_requests m JOIN rooms r USING (room_id)
                 WHERE m.request_status IN ('pending', 'in_progress')) AS open_maintenance,
                (SELECT count(*) FROM bills WHERE bill_status = 'unpaid') AS unpaid_bills,
                (SELECT COALESCE(sum(pay.amount_paid), 0) FROM public.payments pay JOIN bills USING (bill_id)
                 WHERE pay.payment_status = 'completed') AS payments_received
            """, (owner_id,),
        ).fetchone()


@app.put("/admin/properties/{property_id}/verify")
def verify_property(property_id: int, request: Request):
    with connect() as db:
        user = profile_user(db, request)
        if user["role_name"] not in ("admin", "platform_admin"):
            raise HTTPException(403, "Platform admin account required.")
        if db.execute(
            "SELECT 1 FROM public.properties WHERE property_id = %s FOR UPDATE", (property_id,),
        ).fetchone() is None:
            raise HTTPException(404, "Property not found.")
        row = db.execute(
            """
            INSERT INTO public.boardease_listing_status (property_id, verified)
            VALUES (%s, TRUE)
            ON CONFLICT (property_id) DO UPDATE SET verified = TRUE
            RETURNING property_id, verified, published, archived
            """, (property_id,),
        ).fetchone()
        _owner_log(db, user["user_id"], f"Verified property #{property_id}")
        return row


class TenantProfileInput(BaseModel):
    full_name: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=150)]
    phone_number: Annotated[str, StringConstraints(strip_whitespace=True, max_length=20)] = ""


@app.put("/tenant/profile")
def edit_tenant_profile(form: TenantProfileInput, request: Request):
    with connect() as db:
        tenant = lock_boarder(db, require_role(db, request, "tenant"))
        row = db.execute(
            """
            UPDATE public.tenants SET full_name = %s, phone_number = %s WHERE tenant_id = %s
            RETURNING tenant_id, user_id, full_name, email, phone_number
            """, (form.full_name, form.phone_number or None, tenant["tenant_id"]),
        ).fetchone()
        db.execute("UPDATE public.users SET full_name = %s, phone_number = %s WHERE user_id = %s",
                   (form.full_name, form.phone_number or None, row["user_id"]))
        return row
