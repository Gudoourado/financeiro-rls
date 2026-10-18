-- Q1: os lançamentos do mês (a consulta mais usada do app: tela de resumo e lista de lançamentos).
-- No app, o mês vai como $1; aqui, como :'mes'. Sem filtro de usuário: quem filtra é o RLS.
SELECT id, tipo, valor_centavos, data_lancamento, mes_competencia, descricao, forma_pagamento,
       conta_id, conta_destino_id, cartao_id, fatura_id, categoria_id,
       compra_parcelada_id, parcela_numero, parcela_total, origem
  FROM lancamento
 WHERE mes_competencia = :'mes' AND removido_em IS NULL
 ORDER BY data_lancamento DESC, criado_em DESC, parcela_numero NULLS FIRST, id
