-- 0000_roles.sql
-- Run ONCE as a superuser (postgres). local_ops has CREATEDB but not CREATEROLE,
-- so role creation cannot live in 0001.
-- Roles are created LOGIN without passwords: they cannot authenticate until the
-- operator sets one manually (ALTER ROLE ... PASSWORD). Passwords are never committed.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ops_planner') THEN
    CREATE ROLE ops_planner LOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ops_executor') THEN
    CREATE ROLE ops_executor LOGIN;
  END IF;
END
$$;

-- Actors may connect to the database; object-level grants are in 0001.
GRANT CONNECT ON DATABASE local_ops TO ops_planner, ops_executor;
