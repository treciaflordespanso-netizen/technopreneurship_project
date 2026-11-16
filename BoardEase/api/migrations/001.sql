BEGIN;
CREATE TABLE public.boardease_sessions (
    token_hash text PRIMARY KEY,
    user_id integer NOT NULL REFERENCES public.users(user_id),
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz
);
CREATE TABLE public.boardease_listing_status (
    property_id integer PRIMARY KEY REFERENCES public.properties(property_id),
    verified boolean NOT NULL DEFAULT false,
    published boolean NOT NULL DEFAULT false,
    archived boolean NOT NULL DEFAULT false
);
COMMIT;
