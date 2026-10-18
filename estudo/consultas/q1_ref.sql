-- Q1 de referência: a mesma consulta com o filtro de usuário explícito, rodada como superusuário (sem RLS).
SELECT id, tipo, valor_centavos, data_lancamento, mes_competencia, descricao, forma_pagamento,
       conta_id, conta_destino_id, cartao_id, fatura_id, categoria_id,
       compra_parcelada_id, parcela_numero, parcela_total, origem
  FROM lancamento
 WHERE mes_competencia = :'mes' AND removido_em IS NULL AND usuario_id = :'uid'
 ORDER BY data_lancamento DESC, criado_em DESC, parcela_numero NULLS FIRST, id
