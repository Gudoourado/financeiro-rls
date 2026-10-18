-- Desfaz o cenário C (volta aos índices da migração). Roda como app_migrador, no estudo_rls.
\set ON_ERROR_STOP 1
DROP INDEX IF EXISTS lancamento_ultimo_criado;
DROP INDEX IF EXISTS lancamento_mes_ordenado;
ANALYZE lancamento;
