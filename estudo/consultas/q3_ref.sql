-- Q3 de referência: filtro de usuário explícito, como superusuário (sem RLS).
SELECT forma_pagamento, conta_id, cartao_id
  FROM lancamento
 WHERE tipo = 'gasto' AND forma_pagamento IS NOT NULL AND removido_em IS NULL AND usuario_id = :'uid'
 ORDER BY criado_em DESC, id DESC
 LIMIT 1
