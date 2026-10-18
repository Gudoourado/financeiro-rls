# Estudo de desempenho do RLS por usuário

Data das medições: 15/10/2026, das 03:23 às 03:32 (horário de Brasília). Todo número deste relatório saiu de uma
medição guardada. As saídas publicadas estão em `resultados/` (o resumo completo, os planos escolhidos, a contagem
de chamadas da função e a conferência de isolamento); os scripts que geraram cada número estão em `estudo/`.

Os números valem **nestas consultas, com esta carga e este ambiente**. A direção dos efeitos é o que se espera
reproduzir em outra máquina; os valores absolutos, não.

## Resumo

- **A consulta mais usada, a lista de lançamentos do mês (Q1), já está bem servida.** O RLS usa o índice
  `lancamento_mes_ativo` e o custo dele não se distingue do ruído: a mediana fica entre 6 e 7 ms para o usuário
  com mais dados e abaixo de 0,4 ms para os outros, com RLS ou sem.
- **O gargalo real é outra consulta: o "último meio de gasto" da tela de lançar (Q3).** Para o usuário pesado ela
  lê as 116 mil linhas ativas dele e leva **325 a 335 ms** (mediana; p95 de 554 a 612 ms). Com um índice parcial
  `(usuario_id, criado_em DESC, id DESC) WHERE removido_em IS NULL`, ela lê **1 linha** e cai para **0,09 a
  0,10 ms**. Essa foi a mudança adotada (`migrations/03_ultimo_meio_de_gasto.sql`).
- **Reescrever a política com `(SELECT app_usuario_atual())` (initPlan) não ajudou e piorou um caso.** A função
  já é `STABLE` e já rodava uma vez por consulta nos índices. Com o initPlan, o planejador deixa de saber qual
  usuário está consultando. Na Q2 (faturas do resumo), o usuário pesado passou de **8 ms para 74 a 87 ms**.
  **A ideia foi descartada.**
- O isolamento entre usuários continuou intacto: **49 conferências de 49** passaram, tanto no estado atual (A)
  quanto no estado com as duas mudanças (D).

## Ambiente

| Item | Valor |
|---|---|
| Máquina | Notebook com CPU AMD de 4 núcleos e 8 threads, 13,7 GB de RAM visíveis ao sistema, Windows 11 |
| Docker | Docker Desktop 29.4.3, VM WSL2, 8 CPUs e cerca de 5,8 GB de memória para a VM |
| PostgreSQL | **17.11** (Debian 17.11-1.pgdg13+2), imagem oficial `postgres:17` |
| Configuração do PostgreSQL | Padrão da imagem: `shared_buffers` 128MB, `work_mem` 4MB, `effective_cache_size` 4GB, `random_page_cost` 4, `jit` on, `max_parallel_workers_per_gather` 2 |
| Banco | Um banco criado só para o estudo e apagado no fim |
| Esquema | As migrações `01_nucleo.sql` e `02_multiusuario.sql`, aplicadas como `app_migrador` (a `03` é a mudança que este estudo recomendou e ainda não existia) |
| Carga simultânea | Outros contêineres do mesmo app ficaram ligados e ociosos durante as medições |

### Volume de dados (todo fictício, gerado com `generate_series` e `random()`, semente `setseed(0.27)`)

| Tabela | Linhas |
|---|---|
| usuario | 200 |
| instituicao / conta / cartao / categoria | 400 / 600 / 400 / 3.000 |
| fatura | 24.400 (61 meses × 2 cartões × 200 usuários) |
| compra_parcelada | 2.000 |
| **lancamento** | **1.393.270** (heap de 255 MB, 333 MB com os índices) |
| evento_de_uso | 10.000 |

- A distribuição é assimétrica, por lei de potência: o usuário de posto *r* tem `round(120000 · r^-0,75)`
  lançamentos, espalhados por 60 meses (nov/2021 a out/2026). O mínimo é 2.256, a mediana 3.767, a média 6.966 e o
  máximo 120.000.
- A mistura de tipos é 70% gasto (metade em conta, metade no cartão com fatura, 5% parcelados), 15% entrada,
  8% transferência, 4% pagamento de fatura e 3% estorno. Cerca de 3% das linhas estão removidas
  (`removido_em`). Todas as CHECKs e as chaves estrangeiras compostas ficaram ligadas na carga, que levou
  3 min 50 s.
- As linhas entraram em ordem de `criado_em`. No disco, os lançamentos de todos os usuários ficam intercalados no
  tempo, como num app em que cada pessoa lança aos poucos.
- Perfis medidos:
  - **pesado**: posto 1, 120.000 lançamentos, 1.909 ativos em 2026-09.
  - **mediano**: posto 100, 3.795 lançamentos, 55 ativos em 2026-09.
  - **leve**: posto 200, 2.256 lançamentos, 37 ativos em 2026-09.

## O que já existia

`public.app_usuario_atual()` (`migrations/02_multiusuario.sql`):

- Linguagem **plpgsql**, **STABLE**, SECURITY INVOKER, com `SET search_path = pg_catalog, pg_temp`, custo 100
  e paralelismo `u` (unsafe).
- Lê `current_setting('app.usuario_id', true)` e dá erro `app_usuario_ausente` se o valor faltar. **Não faz
  SELECT em nenhuma tabela.**
- Por ser STABLE, o PostgreSQL pode usá-la como chave de índice (`Index Cond: usuario_id = app_usuario_atual()`).
  Nesse caso ela é avaliada uma vez por varredura, não uma vez por linha. Na estimativa do planejamento, o
  planejador também a avalia e enxerga o usuário de verdade (é a chamada extra que aparece na contagem abaixo).
- Medido com `track_functions = 'pl'` (`resultados/05_chamadas.txt`): no estado A, a Q1 e a Q3 chamam a função
  **2 vezes por consulta** (uma no planejamento e uma na execução). O único caso de chamada por linha foi a Q2 do
  usuário pesado: **1.525 chamadas**, porque ali a política entra como `Filter` linha a linha.

Índices em `lancamento` na migração 02: `lancamento_pkey (id)`,
`lancamento_mes_ativo (usuario_id, mes_competencia) WHERE removido_em IS NULL`,
`lancamento_da_compra (compra_parcelada_id)` e `lancamento_da_fatura (fatura_id)`, os dois parciais.

- As demais tabelas do núcleo têm `UNIQUE (usuario_id, id)` e índices únicos de nome que começam por
  `usuario_id`.
- `evento_de_uso` não tem índice em `usuario_id`. Não foi medida, porque o app não tem consulta de leitura dela.

## As consultas medidas

Todas vêm do repositório de lançamentos do app. Nenhuma tem filtro de usuário no SQL: quem filtra é o RLS.

| Id | O que é | Quem chama |
|---|---|---|
| **Q1** (principal) | Lançamentos do mês | A tela de resumo e a lista de lançamentos, que a chama duas vezes (lista e painel) |
| Q2 | Lançamentos das faturas do mês e do seguinte | A tela de resumo, junto com a Q1 |
| Q3 | Último meio de gasto | A tela de lançar |

```sql
-- Q1 (estudo/consultas/q1.sql); mes = '2026-09'
SELECT id, tipo, valor_centavos, data_lancamento, mes_competencia, descricao, forma_pagamento,
       conta_id, conta_destino_id, cartao_id, fatura_id, categoria_id,
       compra_parcelada_id, parcela_numero, parcela_total, origem
  FROM lancamento
 WHERE mes_competencia = '2026-09' AND removido_em IS NULL
 ORDER BY data_lancamento DESC, criado_em DESC, parcela_numero NULLS FIRST, id;
```

A Q1 real **não tem LIMIT**: devolve o mês inteiro. A Q3 é a única com `ORDER BY ... LIMIT 1`. Os textos da Q2 e
da Q3 estão em `estudo/consultas/`. O app manda o mês como `$1`, pelo protocolo estendido do node-pg (instrução sem
nome, com plano feito para o valor). Aqui o valor vai como literal, o que dá ao planejador a mesma informação.

## Método

- **Papel:** cada execução roda como **`app_runtime`** (o papel real do app: sem superusuário, sem BYPASSRLS, sem
  posse de tabela), numa transação própria, no mesmo formato da unidade de trabalho do app:
  `BEGIN; SELECT set_config('app.usuario_id', '<uuid>', true); EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) <consulta>; COMMIT;`.
- **Estatísticas:** `VACUUM (ANALYZE)` de todas as tabelas logo depois da carga, e `ANALYZE lancamento` a cada
  troca de índices (`estudo/cenarios/`). Toda medição roda com estatística fresca.
- **Repetições:** cada série (cenário × consulta × perfil) tem **1 aquecimento + 30 medições**. O número usado é o
  `Execution Time`: **mediana** e **p95** por posto mais próximo, que com 30 medições é a 29ª.
- **Duas rodadas:** o roteiro inteiro (`estudo/00_rodar_tudo.sh`) rodou **duas vezes seguidas** (rodadas 1 e 2),
  para mostrar quanto o resultado varia nesta máquina.
- **Cache:** quente no sistema, não no PostgreSQL. As medições têm aquecimento e a tabela cabe no cache de páginas
  do Linux da VM, mas não nos 128 MB de `shared_buffers`. Não houve medição com cache frio.
- **Instrumentação:** o `EXPLAIN ANALYZE` mede com instrumentação (relógio em cada nó), o que acrescenta custo, e
  **não mede o envio das linhas ao cliente** nem a rede. Por isso, para o usuário pesado, cada série também rodou
  no `pgbench` (30 transações `BEGIN; set_config; consulta; COMMIT`, sem EXPLAIN). A coluna "pgbench" mostra a
  latência média medida no cliente, dentro do contêiner, pelo socket local (sem rede).
- **"Linhas lidas"** soma, nos nós de leitura do heap, as linhas devolvidas e as descartadas por `Filter` ou
  `Recheck`.
- **Referência sem RLS:** a mesma consulta com `AND usuario_id = '<uuid>'` explícito (na Q2, nas duas tabelas,
  como o RLS faz), rodada como `postgres`, que é superusuário e ignora o RLS. `REF_A` usa os índices da migração e
  `REF_C`, os índices do cenário C.

Os cenários são estes (`estudo/cenarios/`):

| Cenário | Política | Índices |
|---|---|---|
| A | Original da migração (`usuario_id = public.app_usuario_atual()`) | Os da migração 02 |
| B | `usuario_id = (SELECT public.app_usuario_atual())`, nas 8 tabelas, em USING e WITH CHECK | Os da migração 02 |
| C | Original | Os da migração 02 + `lancamento_ultimo_criado (usuario_id, criado_em DESC, id DESC) WHERE removido_em IS NULL` + `lancamento_mes_ordenado (usuario_id, mes_competencia, data_lancamento DESC, criado_em DESC, parcela_numero NULLS FIRST, id) WHERE removido_em IS NULL` |
| D | A de B | Os de C |

## Resultados

Tempos em ms. "r1 / r2" são as medianas da rodada 1 e da rodada 2. A tabela completa, com mínimo, máximo,
buffers e o plano de cada série, está em `resultados/resumo.txt`.

### Q3: último meio de gasto (tela de lançar), onde está o ganho

| Cenário | Perfil | Mediana r1 / r2 | p95 r1 / r2 | pgbench r1 / r2 | Linhas lidas | Plano |
|---|---|---|---|---|---|---|
| A | pesado | **335,2 / 325,1** | 612,4 / 554,2 | 479,1 / 347,8 | 116.283 | Limit > Sort (top-N) > Bitmap Heap Scan > Bitmap Index Scan (`lancamento_mes_ativo`) |
| A | mediano | 9,63 / 7,81 | 16,7 / 12,4 | – | 3.670 | igual |
| A | leve | 6,84 / 5,23 | 12,8 / 6,62 | – | 2.200 | igual |
| B | pesado | 323,0 / 245,3 | 545,0 / 567,4 | 297,2 / 274,4 | 116.283 | igual, com InitPlan |
| C | pesado | **0,10 / 0,09** | 0,23 / 0,20 | 1,08 / 0,63 | **1** | Limit > Index Scan (`lancamento_ultimo_criado`) |
| C | mediano | 0,10 / 0,10 | 0,19 / 0,17 | – | 1 | igual |
| C | leve | 0,08 / 0,08 | 0,23 / 0,12 | – | 1 | igual |
| D | pesado | 0,14 / 0,17 | 0,20 / 0,29 | 1,70 / 1,24 | 1 | Limit > Index Scan, com InitPlan |
| REF_A | pesado | 331,0 / 301,5 | 597,6 / 536,5 | 346,6 / 310,7 | 116.283 | o mesmo de A |
| REF_C | pesado | 0,08 / 0,08 | 0,11 / 0,16 | 0,84 / 1,04 | 1 | o mesmo de C |

Planos: `resultados/planos/r1_A_q3_pesado.txt` (antes do índice), `r1_C_q3_pesado.txt` (depois) e
`r1_REF_A_q3_pesado.txt` (referência sem RLS, antes do índice).

### Q1: lançamentos do mês (a consulta principal)

| Cenário | Perfil | Mediana r1 / r2 | p95 r1 / r2 | pgbench r1 / r2 | Linhas lidas | Plano |
|---|---|---|---|---|---|---|
| A | pesado | 6,78 / 7,37 | 12,5 / 15,9 | 12,5 / 18,3 | 1.909 | Sort > Bitmap Heap Scan > Bitmap Index Scan (`lancamento_mes_ativo`) |
| A | mediano | 0,34 / 0,31 | 0,65 / 0,48 | – | 55 | Sort > Index Scan (`lancamento_mes_ativo`) |
| A | leve | 0,30 / 0,27 | 0,47 / 0,55 | – | 37 | igual |
| B | pesado | 5,82 / 7,01 | 7,66 / 14,1 | 13,2 / 14,3 | 1.909 | Sort > Bitmap Heap Scan, com InitPlan |
| B | mediano | 0,40 / 0,38 | 0,70 / 0,81 | – | 55 | Sort > Bitmap Heap Scan, com InitPlan |
| C | pesado | 6,13 / 5,90 | 7,83 / 7,10 | 12,6 / 12,0 | 1.909 | o mesmo de A: o planejador não usou o índice novo |
| C | mediano | 0,24 / 0,22 | 0,39 / 0,38 | – | 55 | Index Scan (`lancamento_mes_ordenado`), sem Sort |
| C | leve | 0,19 / 0,19 | 0,49 / 0,26 | – | 37 | igual |
| D | pesado | 7,43 / 6,35 | 14,5 / 8,20 | 17,4 / 8,63 | 1.909 | o mesmo de B |
| REF_A | pesado | 13,1 / 6,68 | 17,4 / 15,7 | 11,3 / 18,4 | 1.909 | o mesmo de A |
| REF_A | mediano | 0,33 / 0,33 | 0,61 / 0,39 | – | 55 | Sort > Bitmap Heap Scan |

### Q2: lançamentos das faturas (resumo), o resultado ruim

| Cenário | Perfil | Mediana r1 / r2 | p95 r1 / r2 | pgbench r1 / r2 | Linhas lidas (lancamento) | Plano do lado de `lancamento` |
|---|---|---|---|---|---|---|
| A | pesado | 8,41 / 8,12 | 14,4 / 16,2 | 12,5 / 8,75 | 1.576 | Bitmap Heap Scan por `lancamento_da_fatura`; a política entra como `Filter` (1.525 chamadas da função) |
| A | mediano | 3,59 / 3,86 | 7,16 / 8,05 | – | 44 | BitmapAnd (`lancamento_da_fatura` + `lancamento_mes_ativo`) |
| B | pesado | **74,1 / 86,9** | 114,6 / 154,6 | 71,4 / 74,2 | 1.520 | BitmapAnd: varre 116.283 entradas do índice 4 vezes |
| B | mediano | 3,61 / 3,44 | 9,12 / 10,7 | – | 44 | BitmapAnd |
| C | pesado | 7,43 / 6,15 | 14,7 / 7,83 | 10,9 / 13,2 | 1.576 | o mesmo de A |
| D | pesado | **136,1 / 62,5** | 193,4 / 83,1 | 65,3 / 71,9 | 1.520 | o mesmo de B |
| D | mediano | 3,29 / 2,92 | 4,09 / 3,41 | – | 44 | BitmapAnd |
| REF_A | pesado | 3,06 / 3,04 | 11,9 / 4,39 | 7,26 / 5,00 | 1.576 | o mesmo de A, com filtro constante |
| REF_A | mediano | 3,48 / 3,07 | 12,0 / 9,12 | – | 44 | BitmapAnd |

Planos: `resultados/planos/r1_A_q2_pesado.txt` (política com a função chamada direto),
`r1_B_q2_pesado.txt` (política com `(SELECT app_usuario_atual())`, o initPlan) e `r1_REF_A_q2_pesado.txt`
(referência sem RLS). No plano B, o `Bitmap Index Scan on lancamento_mes_ativo` estima `rows=6750` (o "usuário
médio") e devolve `rows=116283`, em 4 loops.

Nas 108 séries (2 rodadas × 6 cenários × 3 consultas × 3 perfis), as linhas devolvidas foram as mesmas em todos
os cenários.

## O que mudou e por quê

**A (linha de base).**

- A função STABLE vira chave de índice. Na Q1 e na Q3, ela é chamada 2 vezes por consulta, não uma por linha.
- O planejador avalia a função ao estimar e enxerga o usuário de verdade. No índice da Q3, ele estima 116.915
  linhas para o pesado (real: 116.283) e 3.780 para o mediano (real: 3.670). Por isso escolhe um plano diferente
  para cada perfil.
- O problema da Q3 não é o RLS. Falta um índice na ordem do `ORDER BY criado_em DESC`, e o banco lê todas as
  linhas ativas do usuário para achar uma. Para o pesado, são 31.965 páginas de 8 kB, quase a tabela inteira.

**B (política com initPlan).**

- O objetivo era chamar a função uma vez por consulta. Ele foi cumprido: 1 a 2 chamadas em vez de 2, e na Q2 do
  pesado, 2 em vez de 1.525.
- Mas no estado A já havia só 2 chamadas na maioria dos casos, e economizar uma chamada não se vê no tempo.
- O efeito colateral pesou mais. Com o initPlan, o valor do usuário só existe na execução. O planejador passa a
  estimar um "usuário médio" (6.750 linhas) e, na Q2, escolhe para o usuário pesado o mesmo BitmapAnd que serve
  aos pequenos. Esse BitmapAnd varre as 116.283 entradas do usuário no índice uma vez por fatura (4 vezes).
- Resultado: a Q2 do pesado passou de 8 ms para 74 a 87 ms (o pgbench confirma: 71 a 74 ms). Na Q1 e na Q3, B
  ficou dentro do ruído.

**C (índices).**

- O índice `lancamento_ultimo_criado` resolve a Q3: um Index Scan com Limit 1 lê 4 páginas. O tempo cai de cerca
  de 330 ms para cerca de 0,1 ms no pesado (cerca de 3.000 vezes) e de 6 a 10 ms para 0,1 ms nos outros perfis.
- O índice `lancamento_mes_ordenado` tira o Sort da Q1 só para os usuários pequenos (de 0,27–0,34 ms para
  0,19–0,24 ms; cerca de 0,1 ms de ganho absoluto). Para o pesado, o planejador continua no índice antigo com
  Sort, e não há ganho.
- Esse segundo índice ocupa 111 MB, contra 15 MB do `lancamento_mes_ativo`. **Resultado neutro: não vale o
  custo.**
- A Q2 não muda com C.

**D (B + C).**

- Junta o ganho de C na Q3 e a piora de B na Q2. Na Q3, D (0,14–0,17 ms) é um pouco mais lento que C
  (0,09–0,10 ms) pelo initPlan, uma diferença sem importância prática.
- Na Q2 do pesado, D herda a piora de B: 62 a 136 ms. A diferença entre as rodadas é ruído desta máquina.

**O custo do RLS em si (A contra REF_A, C contra REF_C).**

- Na Q1 e na Q3, com RLS e sem RLS, os planos são iguais e os tempos ficam dentro do ruído. Exemplos: Q3 pesado
  com RLS em 335/325 ms e sem RLS em 331/302 ms; Q3 com índice em 0,09–0,10 ms com RLS e 0,08 ms sem.
- A Q2 do pesado é a exceção: com RLS, cerca de 8 ms; sem RLS, cerca de 3 ms. Ali a política vira um `Filter`
  avaliado linha a linha, e cada chamada da função plpgsql com `SET search_path` custa alguns microssegundos.
  São 1.525 chamadas, cerca de 5 ms.
- Isso é pequeno perto da Q3, mas é o único custo mensurável do RLS em si neste estudo.

## Isolamento nos estados A e D

`estudo/07_isolamento.mjs` confere, no banco grande, com dois usuários novos (A com uma linha em cada tabela, B
vazio) e uma transação do `app_runtime` com `set_config` por passo:

- B não vê nada de A, em nenhuma das 8 tabelas com RLS;
- B não muda, não apaga e não move para si as linhas de A;
- B não grava uma linha com o `usuario_id` de A;
- a falha fechada: sem `set_config`, a leitura dá `app_usuario_ausente`;
- o volume: para cada perfil, a contagem com RLS é igual à contagem filtrada como superusuário, e nenhuma linha
  de outro usuário aparece.

Resultado: **49 de 49 conferências OK no estado A e 49 de 49 no estado D**, com a política em initPlan e os
índices novos (`resultados/07_isolamento_A.txt` e `resultados/07_isolamento_D.txt`). A otimização não quebra o
isolamento. Faz sentido: o initPlan só muda quando a função é avaliada, e o índice não muda o que a política
filtra. O teste automático do repositório (`tests/isolamento.test.ts`) cobre o mesmo e mais (chaves estrangeiras
compostas, privilégios do papel e a fronteira da marca), num banco pequeno.

## Limites

- **A máquina é um notebook, com ruído alto.** Na mesma série, o p95 chega a ser 2 vezes a mediana, e algumas
  séries de poucos ms saíram bimodais (por exemplo, 3–4 ms e 11–13 ms se alternando). Por isso as rodadas são
  duas e só são tratadas como reais as diferenças grandes e repetidas nas duas: a Q3 com índice e a Q2 do pesado
  piorando com initPlan.
- Diferenças de 1 a 2 ms na Q1 e na Q2 dos perfis pequenos são ruído, inclusive as que parecem favorecer um
  cenário. Um diagnóstico à parte (`estudo/06_experimento_q2.sql`) mostrou isso: um "A lento" da Q2 mediana numa
  rodada exploratória era só ruído (constante, função direta e subselect deram todos ~2,1 ms).
- **Os dados são sintéticos.** A distribuição por usuário segue uma lei de potência escolhida pelo autor (o maior
  usuário tem 120 mil lançamentos, cerca de 2.000 por mês). Dados reais podem ter outra assimetria. O ganho da Q3
  cresce com o número de lançamentos do usuário, e a piora do initPlan aparece justamente com usuários muito
  acima da média.
- **O cache fica quente no sistema, mas não no PostgreSQL.** A Q3 do pesado lê 31.965 páginas a cada execução,
  vindas do cache do sistema e não do disco. Com disco frio ou armazenamento remoto, a Q3 sem índice tende a ser
  mais lenta, não mais rápida.
- **Uma consulta por vez.** Não houve concorrência, e as escritas não foram medidas. O índice novo custa espaço
  (76 MB com 1,39 milhão de linhas) e um pouco a mais em cada INSERT e UPDATE de lançamento, e isso não foi
  medido.
- O `EXPLAIN ANALYZE` mede com instrumentação e não inclui o envio ao cliente. O pgbench (sem EXPLAIN, medido no
  cliente) confirma a direção e a ordem de grandeza de todos os achados.
- Os valores foram passados como literais, e não como `$1` pelo protocolo estendido. Um mês só (2026-09).
- Entre os estados, o `ANALYZE` refaz a amostra de estatísticas, o que pode mudar estimativas de leve.
- Um servidor de produção tem outra máquina, outra configuração e latência de rede, então os números absolutos não
  valem para lá; a direção dos efeitos, sim.

## Decisão

- **Adotado:** o índice `lancamento_ultimo_criado` (`migrations/03_ultimo_meio_de_gasto.sql`). O runner aplica
  cada migração numa transação, então `CREATE INDEX CONCURRENTLY` não cabe ali; o `CREATE INDEX` comum bloqueia
  escritas em `lancamento` enquanto o índice é construído. O tempo dessa construção não foi cronometrado.
- **Descartado:** trocar a política por `(SELECT public.app_usuario_atual())`. Não houve ganho mensurável e houve
  piora de cerca de 10 vezes na Q2 do usuário pesado. Manter `app_usuario_atual()` STABLE e chamada direto é o que
  deixa o planejador escolher o plano pelo usuário de verdade.
- **Descartado:** o índice `lancamento_mes_ordenado`. O ganho foi de ~0,1 ms só para usuários pequenos, e ele
  ocupa 111 MB.
- **Ideias não medidas, para um próximo estudo:**
  - Uma versão mais enxuta do índice, parcial também em `tipo = 'gasto' AND forma_pagamento IS NOT NULL`.
  - Para o custo de ~5 ms da Q2 do pesado: um índice `(usuario_id, fatura_id) WHERE removido_em IS NULL`, ou
    tornar a função mais barata por chamada (por exemplo, sem a cláusula `SET` de search_path, que hoje protege
    a função).
  - Nenhuma dessas foi medida, e nenhuma deve virar migração sem medição.

## Diferenças entre este repositório e o ambiente medido

Este repositório foi extraído do app original para que o estudo possa ser reproduzido sozinho. O que mudou:

- As migrações foram higienizadas: saíram as tabelas do login (exceto `usuario`, reduzida às colunas usadas), a
  tabela de marca da instância e as políticas de dois papéis auxiliares (leitura de backup e de demonstração), que
  não entram nas consultas medidas. Um valor do CHECK de `origem` foi renomeado. As tabelas, índices, políticas e a
  função medidos são os mesmos.
- O registro de migrações se chama `migracao` e é feito por `scripts/migrar.mjs`, uma migração por transação (no
  app, um runner aplicava todas numa transação só).
- A migração 03 já existe aqui. O roteiro do estudo apaga o índice dela para medir o estado A, como no estudo
  original, que rodou antes de ela existir.
- As medições publicadas em `resultados/` são as do ambiente acima. Rodar o estudo de novo grava em
  `estudo/saidas/`, fora do git.
