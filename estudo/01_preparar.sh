#!/usr/bin/env bash
# Prepara o banco grande do estudo (estudo_rls), separado do banco dos testes: cria e migra, gera os dados fictícios
# (semente fixa) e liga o track_functions que o 05_contar_chamadas.mjs usa. A geração leva alguns minutos.
set -euo pipefail
cd "$(dirname "$0")"
RAIZ=..
BANCO=${ESTUDO_BANCO:-estudo_rls}
PG() { docker compose -f "$RAIZ/compose.yaml" exec -T postgres psql -X -v ON_ERROR_STOP=1 "$@"; }
mkdir -p saidas

npm --prefix "$RAIZ" run --silent migrar -- --banco "$BANCO" | tee saidas/01_preparar.txt
PG -U app_migrador -d "$BANCO" < 02_gerar_dados.sql 2>&1 | tee saidas/02_geracao.txt
PG -U postgres -c "ALTER DATABASE $BANCO SET track_functions = 'pl'" | tee -a saidas/01_preparar.txt
PG -U postgres -d "$BANCO" < 03_inspecao.sql > saidas/03_inspecao_inicio.txt 2>&1
