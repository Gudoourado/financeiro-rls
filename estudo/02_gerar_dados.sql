-- Geração de dados FICTÍCIOS para o estudo de RLS (banco estudo_rls). Roda como app_migrador, dono das tabelas:
-- o dono não passa pelo RLS (as tabelas não têm FORCE ROW LEVEL SECURITY), e todo usuario_id vai explícito,
-- então o DEFAULT app_usuario_atual() nunca é chamado. As chaves estrangeiras compostas ficam ligadas e conferem
-- cada linha. Nada aqui vem de dado real.
\set ON_ERROR_STOP 1
\timing on
SELECT setseed(0.27);  -- reprodutível

-- 200 usuários com volume assimétrico (lei de potência): o usuário de posto r tem round(120000 * r^-0.75)
-- lançamentos ao longo de 60 meses (nov/2021 a out/2026).
CREATE TEMP TABLE u AS
SELECT g AS posto, gen_random_uuid() AS id, round(120000 * power(g, -0.75))::int AS n
  FROM generate_series(1, 200) g;

INSERT INTO usuario (id, nome, email, email_verificado)
SELECT id, 'Pessoa Ficticia ' || posto, 'pessoa' || posto || '@exemplo.test', true FROM u;

-- Cadastros: 2 instituições, 3 contas, 2 cartões, 15 categorias, 10 compras parceladas por usuário.
INSERT INTO instituicao (usuario_id, nome)
SELECT u.id, b.nome FROM u CROSS JOIN (VALUES ('Banco Ficticio A'), ('Banco Ficticio B')) b(nome);

INSERT INTO conta (usuario_id, instituicao_id, nome, tipo)
SELECT u.id, i.id, c.nome, c.tipo
  FROM u JOIN instituicao i ON i.usuario_id = u.id AND i.nome = 'Banco Ficticio A'
 CROSS JOIN (VALUES ('Corrente', 'corrente'), ('Poupanca', 'poupanca')) c(nome, tipo);
INSERT INTO conta (usuario_id, instituicao_id, nome, tipo) SELECT id, NULL, 'Carteira', 'dinheiro' FROM u;

INSERT INTO cartao (usuario_id, instituicao_id, nome, dia_fechamento, dia_vencimento)
SELECT u.id, i.id, 'Cartao ' || i.nome, 25, 5 FROM u JOIN instituicao i ON i.usuario_id = u.id;

INSERT INTO categoria (usuario_id, nome, cor)
SELECT u.id, 'Categoria ' || k, k % 9 FROM u CROSS JOIN generate_series(1, 15) k;

-- Faturas de cada cartão, de nov/2021 a nov/2026 (61 meses).
INSERT INTO fatura (usuario_id, cartao_id, mes_referencia, data_fechamento, data_vencimento)
SELECT c.usuario_id, c.id, to_char(m, 'YYYY-MM'), (m - interval '1 month')::date + 24, m::date + 4
  FROM cartao c CROSS JOIN generate_series(date '2021-11-01', date '2026-11-01', interval '1 month') m;

-- Referências por usuário, em vetores, para sortear sem subconsulta por linha.
CREATE TEMP TABLE ref AS
SELECT u.id AS usuario_id, u.n,
       (SELECT array_agg(id ORDER BY nome) FROM conta x WHERE x.usuario_id = u.id) AS contas,   -- Carteira, Corrente, Poupanca
       (SELECT array_agg(id ORDER BY nome) FROM cartao x WHERE x.usuario_id = u.id) AS cartoes,
       (SELECT array_agg(id ORDER BY nome) FROM categoria x WHERE x.usuario_id = u.id) AS categorias
  FROM u;

INSERT INTO compra_parcelada (usuario_id, cartao_id, categoria_id, descricao, valor_total_centavos, parcelas, data_compra)
SELECT r.usuario_id, r.cartoes[1], r.categorias[1 + (k % 15)], 'Compra parcelada ficticia ' || k,
       10000 + k * 1000, 2 + (k % 11), date '2021-11-01' + k * 30
  FROM ref r CROSS JOIN generate_series(1, 10) k;

ALTER TABLE ref ADD COLUMN compras uuid[], ADD COLUMN parcelas smallint[];
UPDATE ref SET compras = s.ids, parcelas = s.ps
  FROM (SELECT usuario_id, array_agg(id ORDER BY descricao) ids, array_agg(parcelas ORDER BY descricao) ps
          FROM compra_parcelada GROUP BY usuario_id) s
 WHERE s.usuario_id = ref.usuario_id;

-- Lançamentos. Cada linha sorteia o tipo e o meio respeitando as CHECKs do núcleo:
--   35% gasto em conta (pix/débito/dinheiro), 35% gasto no cartão (crédito, com fatura; 10% deles parcelados),
--   15% entrada, 8% transferência, 4% pagamento de fatura, 3% estorno no cartão. 3% das linhas são removidas.
-- A inserção sai em ordem de criado_em: no disco, as linhas de todos os usuários ficam intercaladas no tempo,
-- como num app em que cada pessoa lança aos poucos (e não agrupadas por usuário).
SET work_mem = '256MB';  -- só nesta sessão, para a ordenação abaixo
CREATE TEMP TABLE base AS
SELECT r.usuario_id, random() AS x, random() AS y, random() AS z,
       (date '2021-11-01' + floor(random() * 1826)::int) AS data_l
  FROM ref r CROSS JOIN LATERAL generate_series(1, r.n);

CREATE TEMP TABLE lanc AS
SELECT b.usuario_id,
       CASE WHEN x < 0.70 THEN 'gasto' WHEN x < 0.85 THEN 'entrada'
            WHEN x < 0.93 THEN 'transferencia' WHEN x < 0.97 THEN 'pagamento_fatura' ELSE 'estorno' END AS tipo,
       (100 + floor(y * 50000))::bigint AS valor_centavos,
       data_l AS data_lancamento,
       to_char(data_l, 'YYYY-MM') AS mes_competencia,
       CASE WHEN x < 0.35 THEN (ARRAY['pix', 'debito', 'dinheiro'])[1 + floor(z * 3)::int]
            WHEN x < 0.70 OR x >= 0.97 THEN 'credito' END AS forma_pagamento,
       CASE WHEN x < 0.35 THEN CASE WHEN z >= 2.0/3 THEN r.contas[1] ELSE r.contas[2] END   -- dinheiro na Carteira
            WHEN x >= 0.70 AND x < 0.97 THEN r.contas[2] END AS conta_id,
       CASE WHEN x >= 0.85 AND x < 0.93 THEN r.contas[3] END AS conta_destino_id,
       -- 10% dos gastos no cartão (x entre 0.35 e 0.385) são parcela de uma compra, sempre no cartão 1 (o das compras)
       CASE WHEN x >= 0.35 AND x < 0.385 THEN r.cartoes[1]
            WHEN (x >= 0.35 AND x < 0.70) OR x >= 0.93 THEN r.cartoes[1 + floor(z * 2)::int] END AS cartao_id,
       CASE WHEN x < 0.70 OR x >= 0.97 THEN r.categorias[1 + floor(y * 15)::int] END AS categoria_id,
       CASE WHEN x >= 0.35 AND x < 0.385 THEN r.compras[1 + floor(z * 10)::int] END AS compra_parcelada_id,
       CASE WHEN x >= 0.35 AND x < 0.385 THEN r.parcelas[1 + floor(z * 10)::int] END AS parcela_total,
       CASE WHEN floor(y * 1000)::int % 33 = 0 THEN data_l + interval '3 days' END AS removido_em,
       data_l + (z * interval '86399 seconds') AS criado_em
  FROM base b JOIN ref r ON r.usuario_id = b.usuario_id;
DROP TABLE base;

INSERT INTO lancamento (usuario_id, tipo, valor_centavos, data_lancamento, mes_competencia, descricao, forma_pagamento,
                        conta_id, conta_destino_id, cartao_id, fatura_id, categoria_id, compra_parcelada_id,
                        parcela_numero, parcela_total, origem, removido_em, criado_em, atualizado_em)
SELECT l.usuario_id, l.tipo, l.valor_centavos, l.data_lancamento, l.mes_competencia, 'Lancamento ficticio',
       l.forma_pagamento, l.conta_id, l.conta_destino_id, l.cartao_id, f.id, l.categoria_id, l.compra_parcelada_id,
       CASE WHEN l.compra_parcelada_id IS NOT NULL
            THEN 1 + (floor(extract(epoch FROM l.criado_em))::bigint % l.parcela_total) END,
       l.parcela_total,
       CASE WHEN l.valor_centavos % 10 = 0 THEN 'frase' ELSE 'formulario' END,
       l.removido_em, l.criado_em, l.criado_em
  FROM lanc l
  LEFT JOIN fatura f
    ON l.tipo IN ('gasto', 'estorno') AND f.cartao_id = l.cartao_id AND f.mes_referencia = l.mes_competencia
 ORDER BY l.criado_em;
DROP TABLE lanc;
RESET work_mem;

-- Alguns eventos de uso, só para a tabela não ficar vazia.
INSERT INTO evento_de_uso (usuario_id, tipo, criado_em)
SELECT u.id, 'lancamento', timestamptz '2026-01-01' + k * interval '1 day' FROM u CROSS JOIN generate_series(1, 50) k;

VACUUM (ANALYZE) usuario, instituicao, conta, cartao, categoria, fatura, compra_parcelada, lancamento, evento_de_uso;

\echo '== Volume gerado =='
SELECT 'usuario' tabela, count(*) FROM usuario UNION ALL SELECT 'instituicao', count(*) FROM instituicao
UNION ALL SELECT 'conta', count(*) FROM conta UNION ALL SELECT 'cartao', count(*) FROM cartao
UNION ALL SELECT 'categoria', count(*) FROM categoria UNION ALL SELECT 'fatura', count(*) FROM fatura
UNION ALL SELECT 'compra_parcelada', count(*) FROM compra_parcelada UNION ALL SELECT 'lancamento', count(*) FROM lancamento
UNION ALL SELECT 'evento_de_uso', count(*) FROM evento_de_uso;
\echo '== Lançamentos por tipo / removidos / parcelas / com fatura =='
SELECT tipo, count(*), count(*) FILTER (WHERE removido_em IS NOT NULL) removidos,
       count(*) FILTER (WHERE compra_parcelada_id IS NOT NULL) parcelas, count(*) FILTER (WHERE fatura_id IS NOT NULL) com_fatura
  FROM lancamento GROUP BY tipo ORDER BY 2 DESC;
\echo '== Distribuição por usuário (lançamentos) =='
SELECT min(c), percentile_disc(0.5) WITHIN GROUP (ORDER BY c) mediana, max(c), round(avg(c)) media
  FROM (SELECT count(*) c FROM lancamento GROUP BY usuario_id) s;
\echo '== Tamanho em disco =='
SELECT pg_size_pretty(pg_total_relation_size('lancamento')) total_lancamento,
       pg_size_pretty(pg_relation_size('lancamento')) heap_lancamento,
       pg_size_pretty(pg_database_size(current_database())) banco;
