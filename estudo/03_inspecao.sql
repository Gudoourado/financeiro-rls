-- Inspeção do estado do banco do estudo: função, políticas e índices (rodar como postgres).
\echo '== Função app_usuario_atual: linguagem, volatilidade, segurança, paralelismo, custo =='
SELECT p.proname, l.lanname AS linguagem,
       CASE p.provolatile WHEN 'v' THEN 'VOLATILE' WHEN 's' THEN 'STABLE' WHEN 'i' THEN 'IMMUTABLE' END AS volatilidade,
       p.prosecdef AS security_definer, p.proparallel AS paralelo, p.procost AS custo, p.proconfig AS configuracao
  FROM pg_proc p JOIN pg_language l ON l.oid = p.prolang
 WHERE p.proname = 'app_usuario_atual';
\echo '== Corpo da função =='
SELECT pg_get_functiondef('public.app_usuario_atual()'::regprocedure);

\echo '== Políticas RLS =='
SELECT tablename, policyname, roles, cmd, qual, with_check FROM pg_policies ORDER BY tablename, policyname;

\echo '== Tabelas com RLS ligado / forçado =='
SELECT relname, relrowsecurity, relforcerowsecurity, pg_get_userbyid(relowner) AS dono
  FROM pg_class WHERE relrowsecurity ORDER BY relname;

\echo '== Índices das tabelas com usuario_id =='
SELECT t.relname AS tabela, i.relname AS indice, pg_get_indexdef(i.oid) AS definicao
  FROM pg_index x
  JOIN pg_class i ON i.oid = x.indexrelid
  JOIN pg_class t ON t.oid = x.indrelid
 WHERE t.relname IN ('instituicao','conta','cartao','categoria','fatura','compra_parcelada','lancamento','evento_de_uso')
 ORDER BY t.relname, i.relname;
