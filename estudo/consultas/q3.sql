-- Q3: o último meio de gasto, que a tela de lançar sugere. Sem filtro de usuário: quem filtra é o RLS.
SELECT forma_pagamento, conta_id, cartao_id
  FROM lancamento
 WHERE tipo = 'gasto' AND forma_pagamento IS NOT NULL AND removido_em IS NULL
 ORDER BY criado_em DESC, id DESC
 LIMIT 1
