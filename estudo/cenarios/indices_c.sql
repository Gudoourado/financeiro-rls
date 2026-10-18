-- Cenário C (e D): índices compostos pensados para as consultas medidas. Roda como app_migrador, no estudo_rls.
--  * Q3 (último meio de gasto): ORDER BY criado_em DESC, id DESC LIMIT 1 por usuário. Hoje não há índice que dê
--    essa ordem; o banco lê todos os lançamentos ativos do usuário e ordena.
--  * Q1 (lançamentos do mês): o filtro já tem índice (lancamento_mes_ativo); este estende o mesmo prefixo com a
--    ordem do ORDER BY, para testar se tirar o Sort compensa.
\set ON_ERROR_STOP 1
CREATE INDEX lancamento_ultimo_criado ON lancamento (usuario_id, criado_em DESC, id DESC) WHERE removido_em IS NULL;
CREATE INDEX lancamento_mes_ordenado ON lancamento
  (usuario_id, mes_competencia, data_lancamento DESC, criado_em DESC, parcela_numero NULLS FIRST, id)
  WHERE removido_em IS NULL;
ANALYZE lancamento;
SELECT indexrelid::regclass AS indice, pg_size_pretty(pg_relation_size(indexrelid)) AS tamanho
  FROM pg_index WHERE indrelid = 'lancamento'::regclass ORDER BY 1;
