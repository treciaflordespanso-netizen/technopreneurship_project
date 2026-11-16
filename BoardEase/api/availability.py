from collections import Counter, defaultdict
from datetime import date, timedelta


OPERATIONAL_BLOCKS = {
    "cleaning": "Cleaning",
    "maintenance": "Under maintenance",
    "under_maintenance": "Under maintenance",
    "unavailable": "Unavailable",
    "inactive": "Unavailable",
}
BOOKABLE_STATUSES = {"available", "occupied", "reserved"}


def peak_occupancy(intervals, start: date, end: date | None = None) -> int:
    """Count distinct occupants at the busiest date, with inclusive end dates."""
    events = defaultdict(Counter)
    for occupant, first, last in intervals:
        if (last is not None and last < start) or (end is not None and first > end):
            continue
        first = max(first, start)
        if last is not None and last < first:
            continue
        events[first][occupant] += 1
        if last is not None and last < date.max and (end is None or last < end):
            events[last + timedelta(days=1)][occupant] -= 1

    active = Counter()
    occupied = peak = 0
    for day in sorted(events):
        for occupant, change in events[day].items():
            before = active[occupant]
            after = before + change
            occupied += int(after > 0) - int(before > 0)
            if after:
                active[occupant] = after
            else:
                active.pop(occupant, None)
        peak = max(peak, occupied)
    return peak


def occupancy_intervals(db, room_id: int, exclude_tenant_id: int | None = None):
    rows = db.execute(
        """
        SELECT COALESCE('tenant:' || a.tenant_id, 'agreement:' || a.agreement_id) AS occupant,
               a.start_date AS first_day, a.end_date AS last_day
        FROM public.rental_agreements AS a
        WHERE a.room_id = %(room)s AND a.agreement_status IN ('pending', 'active')
          AND (%(exclude)s::integer IS NULL OR a.tenant_id IS DISTINCT FROM %(exclude)s)
        UNION ALL
        SELECT 'tenant:' || t.tenant_id, COALESCE(t.move_in_date, DATE '0001-01-01'),
               NULL::date
        FROM public.tenants AS t
        WHERE t.room_id = %(room)s AND COALESCE(t.tenant_status, 'active') = 'active'
          AND (%(exclude)s::integer IS NULL OR t.tenant_id <> %(exclude)s)
          AND NOT EXISTS (
              SELECT 1 FROM public.rental_agreements AS a
              WHERE a.tenant_id = t.tenant_id AND a.room_id = t.room_id
                AND a.agreement_status = 'active'
                AND a.start_date <= CURRENT_DATE
                AND (a.end_date IS NULL OR a.end_date >= CURRENT_DATE)
          )
        UNION ALL
        SELECT COALESCE('tenant:' || res.tenant_id, 'reservation:' || res.reservation_id),
               COALESCE(res.preferred_move_in_date, res.reservation_date, CURRENT_DATE),
               res.requested_end_date
        FROM public.reservations AS res
        WHERE res.room_id = %(room)s AND res.reservation_status IN ('approved', 'confirmed')
          AND res.agreement_id IS NULL
          AND (%(exclude)s::integer IS NULL OR res.tenant_id IS DISTINCT FROM %(exclude)s)
        """,
        {"room": room_id, "exclude": exclude_tenant_id},
    ).fetchall()
    return [(row["occupant"], row["first_day"], row["last_day"]) for row in rows]


def room_availability(db, room, start, end, *, exclude_tenant_id=None):
    occupancy = peak_occupancy(
        occupancy_intervals(db, room["room_id"], exclude_tenant_id), start, end
    )
    open_spaces = max(room["capacity"] - occupancy, 0)
    status = (room["room_status"] or "").strip().lower()
    reason = (
        OPERATIONAL_BLOCKS.get(status, "Unavailable")
        if status not in BOOKABLE_STATUSES
        else ("Fully occupied" if open_spaces == 0 else None)
    )
    return {
        "occupied_spaces": occupancy,
        "available_spaces": 0 if reason else open_spaces,
        "is_available": reason is None,
        "availability_reason": reason,
    }
