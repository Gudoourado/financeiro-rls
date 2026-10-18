-- Papéis do banco. Roda como superusuário (postgres), antes das migrações; as senhas são definidas depois por
-- scripts/migrar.mjs, a partir do .env.
--   app_migrador: dono das tabelas, funções e sequências; aplica as migrações e fica fora do RLS (é o dono).
--   app_runtime:  o papel da aplicação. Não é superusuário, não tem BYPASSRLS, não é dono de nada e não herda
--                 outro papel; por isso o RLS vale para ele.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_migrador') THEN
    CREATE ROLE app_migrador LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_runtime') THEN
    CREATE ROLE app_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT;
  END IF;
END
$$;
