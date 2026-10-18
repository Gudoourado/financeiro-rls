-- Experimento de diagnóstico da Q2 (usuário mediano), como postgres (sem RLS). Mesma consulta da referência, trocando
-- só a forma do filtro de usuário, para separar o custo do RLS em si do custo da forma como a função é chamada.
-- Cada variante: 1 aquecimento + 10 execuções; o resumo pega o Execution Time de cada uma.
-- Uso (da raiz do repositório):
--   docker compose exec -T postgres psql -U postgres -d estudo_rls -v uid=<uuid> < estudo/06_experimento_q2.sql
\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
BEGIN;
SELECT set_config('app.usuario_id', :'uid', true) \g /dev/null
CREATE TEMP TABLE tempos (variante text, i int, ms numeric) ON COMMIT DROP;
DO $$
DECLARE
  variantes text[][] := ARRAY[
    ['1_constante',            $q$l.usuario_id = current_setting('app.usuario_id')::uuid$q$],
    ['2_funcao_direta',        $q$l.usuario_id = public.app_usuario_atual()$q$],
    ['3_funcao_em_subselect',  $q$l.usuario_id = (SELECT public.app_usuario_atual())$q$]
  ];
  v int; i int; plano json; filtro text; uid uuid := current_setting('app.usuario_id')::uuid;
BEGIN
  FOR v IN 1 .. array_length(variantes, 1) LOOP
    filtro := variantes[v][2];
    IF v = 1 THEN filtro := format('l.usuario_id = %L::uuid', uid); END IF;  -- constante de verdade
    FOR i IN 0 .. 10 LOOP
      EXECUTE format($f$EXPLAIN (ANALYZE, FORMAT JSON)
        SELECT f.cartao_id, f.mes_referencia, l.tipo, l.valor_centavos
          FROM lancamento l JOIN fatura f ON f.id = l.fatura_id
         WHERE f.mes_referencia = ANY(ARRAY['2026-09', '2026-10']) AND l.removido_em IS NULL
           AND %s AND %s$f$, filtro, replace(filtro, 'l.usuario_id', 'f.usuario_id')) INTO plano;
      IF i > 0 THEN INSERT INTO tempos VALUES (variantes[v][1], i, (plano->0->>'Execution Time')::numeric); END IF;
      IF i = 10 THEN RAISE NOTICE '% => %', variantes[v][1], plano; END IF;
    END LOOP;
  END LOOP;
END $$;
\pset tuples_only off
\pset format aligned
SELECT variante, count(*) n, percentile_cont(0.5) WITHIN GROUP (ORDER BY ms) mediana_ms, max(ms) max_ms
  FROM tempos GROUP BY variante ORDER BY variante;
COMMIT;
