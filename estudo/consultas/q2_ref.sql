-- Q2 de referência: o RLS põe o filtro de usuário nas duas tabelas; aqui ele vai explícito, como superusuário.
SELECT f.cartao_id, f.mes_referencia, l.tipo, l.valor_centavos
  FROM lancamento l
  JOIN fatura f ON f.id = l.fatura_id
 WHERE f.mes_referencia = ANY(ARRAY[:'mes', :'mes_seguinte']) AND l.removido_em IS NULL
   AND l.usuario_id = :'uid' AND f.usuario_id = :'uid'
