-- Q2: os lançamentos das faturas do mês e do seguinte (tela de resumo, junto com a Q1).
-- No app, $1 = ARRAY[mes, mes seguinte]. Sem filtro de usuário: quem filtra é o RLS.
SELECT f.cartao_id, f.mes_referencia, l.tipo, l.valor_centavos
  FROM lancamento l
  JOIN fatura f ON f.id = l.fatura_id
 WHERE f.mes_referencia = ANY(ARRAY[:'mes', :'mes_seguinte']) AND l.removido_em IS NULL
