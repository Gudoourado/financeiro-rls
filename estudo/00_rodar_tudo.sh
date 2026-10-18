#!/usr/bin/env bash
# Roteiro completo das medições, depois de 01_preparar.sh. Duas rodadas iguais (A, REF_A, B, C, REF_C, D), para
# mostrar quanto o resultado varia de uma rodada para outra na máquina. Depois, a conferência de isolamento no
# estado A e no estado D. Tudo só no banco do estudo (estudo_rls). Saídas em estudo/saidas/.
# Variáveis: RODADAS (padrão "1 2"), MEDICOES (padrão 30), ESTUDO_BANCO (padrão estudo_rls).
set -euo pipefail
cd "$(dirname "$0")"
BANCO=${ESTUDO_BANCO:-estudo_rls}
PG() { docker compose -f ../compose.yaml exec -T postgres psql -X -v ON_ERROR_STOP=1 "$@"; }
MIG() { PG -U app_migrador -d "$BANCO"; }
mkdir -p saidas/cenarios
rm -f saidas/resultados.jsonl saidas/05_chamadas.txt

for RODADA in ${RODADAS:-1 2}; do
  export RODADA
  echo "######## RODADA $RODADA ($(date -Iseconds))"

  echo "== estado A: política original, índices da migração"
  MIG < cenarios/politica_original.sql > "saidas/cenarios/r${RODADA}_1_A_politica.txt"
  MIG < cenarios/sem_indices_c.sql > "saidas/cenarios/r${RODADA}_1_A_indices.txt"
  node 04_medir.mjs A
  node 04_medir.mjs REF_A
  if [ "$RODADA" = 1 ]; then node 05_contar_chamadas.mjs A; fi

  echo "== estado B: política com (SELECT app_usuario_atual()), índices da migração"
  MIG < cenarios/politica_initplan.sql > "saidas/cenarios/r${RODADA}_2_B_politica.txt"
  node 04_medir.mjs B
  if [ "$RODADA" = 1 ]; then node 05_contar_chamadas.mjs B; fi

  echo "== estado C: política original, índices novos"
  MIG < cenarios/politica_original.sql > "saidas/cenarios/r${RODADA}_3_C_politica.txt"
  MIG < cenarios/indices_c.sql > "saidas/cenarios/r${RODADA}_3_C_indices.txt"
  node 04_medir.mjs C
  node 04_medir.mjs REF_C
  if [ "$RODADA" = 1 ]; then node 05_contar_chamadas.mjs C; fi

  echo "== estado D: política com InitPlan + índices novos"
  MIG < cenarios/politica_initplan.sql > "saidas/cenarios/r${RODADA}_4_D_politica.txt"
  node 04_medir.mjs D
  if [ "$RODADA" = 1 ]; then node 05_contar_chamadas.mjs D; fi

  echo "== volta ao estado A"
  MIG < cenarios/politica_original.sql > /dev/null
  MIG < cenarios/sem_indices_c.sql > /dev/null
done

echo "######## ISOLAMENTO ($(date -Iseconds))"
node 07_isolamento.mjs A
MIG < cenarios/politica_initplan.sql > saidas/cenarios/iso_D_politica.txt
MIG < cenarios/indices_c.sql > saidas/cenarios/iso_D_indices.txt
PG -U postgres -d "$BANCO" < 03_inspecao.sql > saidas/03_inspecao_estado_D.txt 2>&1
node 07_isolamento.mjs D
echo "######## FIM ($(date -Iseconds))"
