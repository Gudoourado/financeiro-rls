-- O banco passa a guardar os dados de vários usuários, separados por RLS (docs/adr-0025-rls-por-usuario.md).
-- Esta migração recria o núcleo com usuario_id e chaves estrangeiras compostas. Ela só roda com o núcleo vazio.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM lancamento) OR EXISTS (SELECT 1 FROM compra_parcelada) OR EXISTS (SELECT 1 FROM fatura)
     OR EXISTS (SELECT 1 FROM categoria) OR EXISTS (SELECT 1 FROM cartao) OR EXISTS (SELECT 1 FROM conta)
     OR EXISTS (SELECT 1 FROM instituicao) THEN
    RAISE EXCEPTION 'multiusuario_exige_banco_vazio: o núcleo tem dados; esta migração só roda num banco sem lançamentos nem cadastros.';
  END IF;
END
$$;

DROP TABLE lancamento, compra_parcelada, fatura, categoria, cartao, conta, instituicao;

-- O usuário marcado na transação pela aplicação (set_config('app.usuario_id', <uuid>, true)). Sem marca, dá erro:
-- é a falha fechada do RLS. A função não confere identidade: ela devolve o que a aplicação marcou.
CREATE FUNCTION public.app_usuario_atual() RETURNS uuid
  LANGUAGE plpgsql STABLE SECURITY INVOKER
  SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  valor text := current_setting('app.usuario_id', true);
BEGIN
  IF valor IS NULL OR valor = '' THEN
    RAISE EXCEPTION 'app_usuario_ausente: a transação não marcou o usuário.'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN valor::uuid;
END
$$;

-- Usuários. No app original, esta tabela é a do login; aqui ficam só as colunas que o estudo e os testes usam.
-- Sem RLS: é tabela de sistema.
CREATE TABLE usuario (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nome text NOT NULL CHECK (length(nome) BETWEEN 1 AND 80),
  email text NOT NULL UNIQUE CHECK (email = lower(btrim(email)) AND length(email) BETWEEN 3 AND 254),
  email_verificado boolean NOT NULL DEFAULT false,
  criado_em timestamptz NOT NULL DEFAULT now(),
  atualizado_em timestamptz NOT NULL DEFAULT now()
);

-- Núcleo por usuário. Toda referência leva o usuario_id junto: a conferência de chave estrangeira não passa pelo
-- RLS, e a chave composta impede apontar para o dado de outra pessoa.
CREATE TABLE instituicao (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id uuid NOT NULL DEFAULT public.app_usuario_atual() REFERENCES usuario (id) ON DELETE CASCADE,
  nome text NOT NULL CHECK (length(nome) BETWEEN 1 AND 80),
  criado_em timestamptz NOT NULL DEFAULT now(),
  UNIQUE (usuario_id, id)
);
CREATE UNIQUE INDEX instituicao_nome_por_usuario ON instituicao (usuario_id, lower(nome));

CREATE TABLE conta (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id uuid NOT NULL DEFAULT public.app_usuario_atual() REFERENCES usuario (id) ON DELETE CASCADE,
  instituicao_id uuid,
  nome text NOT NULL CHECK (length(nome) BETWEEN 1 AND 80),
  tipo text NOT NULL CHECK (tipo IN ('corrente', 'poupanca', 'dinheiro')),
  criado_em timestamptz NOT NULL DEFAULT now(),
  UNIQUE (usuario_id, id),
  FOREIGN KEY (usuario_id, instituicao_id) REFERENCES instituicao (usuario_id, id)
);
CREATE UNIQUE INDEX conta_nome_por_usuario ON conta (usuario_id, instituicao_id, lower(nome)) NULLS NOT DISTINCT;

CREATE TABLE cartao (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id uuid NOT NULL DEFAULT public.app_usuario_atual() REFERENCES usuario (id) ON DELETE CASCADE,
  instituicao_id uuid,
  nome text NOT NULL CHECK (length(nome) BETWEEN 1 AND 80),
  dia_fechamento smallint NOT NULL CHECK (dia_fechamento BETWEEN 1 AND 31),
  dia_vencimento smallint NOT NULL CHECK (dia_vencimento BETWEEN 1 AND 31),
  criado_em timestamptz NOT NULL DEFAULT now(),
  UNIQUE (usuario_id, id),
  FOREIGN KEY (usuario_id, instituicao_id) REFERENCES instituicao (usuario_id, id)
);
CREATE UNIQUE INDEX cartao_nome_por_usuario ON cartao (usuario_id, instituicao_id, lower(nome)) NULLS NOT DISTINCT;

CREATE TABLE categoria (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id uuid NOT NULL DEFAULT public.app_usuario_atual() REFERENCES usuario (id) ON DELETE CASCADE,
  nome text NOT NULL CHECK (length(nome) BETWEEN 1 AND 60),
  cor smallint NOT NULL DEFAULT 0 CHECK (cor BETWEEN 0 AND 8),
  criado_em timestamptz NOT NULL DEFAULT now(),
  UNIQUE (usuario_id, id)
);
CREATE UNIQUE INDEX categoria_nome_por_usuario ON categoria (usuario_id, lower(nome));

CREATE TABLE fatura (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id uuid NOT NULL DEFAULT public.app_usuario_atual() REFERENCES usuario (id) ON DELETE CASCADE,
  cartao_id uuid NOT NULL,
  mes_referencia text NOT NULL CHECK (mes_referencia ~ '^\d{4}-(0[1-9]|1[0-2])$'),
  data_fechamento date NOT NULL,
  data_vencimento date NOT NULL,
  criado_em timestamptz NOT NULL DEFAULT now(),
  CHECK (data_vencimento > data_fechamento),
  UNIQUE (cartao_id, mes_referencia),
  UNIQUE (usuario_id, id),
  FOREIGN KEY (usuario_id, cartao_id) REFERENCES cartao (usuario_id, id)
);

CREATE TABLE compra_parcelada (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id uuid NOT NULL DEFAULT public.app_usuario_atual() REFERENCES usuario (id) ON DELETE CASCADE,
  cartao_id uuid NOT NULL,
  categoria_id uuid,
  forma_pagamento text NOT NULL DEFAULT 'credito' CHECK (forma_pagamento IN ('credito', 'pix_credito')),
  descricao text NOT NULL DEFAULT '' CHECK (length(descricao) <= 200),
  valor_total_centavos bigint NOT NULL CHECK (valor_total_centavos > 0),
  parcelas smallint NOT NULL CHECK (parcelas BETWEEN 2 AND 60),
  data_compra date NOT NULL,
  removido_em timestamptz,
  criado_em timestamptz NOT NULL DEFAULT now(),
  UNIQUE (usuario_id, id),
  FOREIGN KEY (usuario_id, cartao_id) REFERENCES cartao (usuario_id, id),
  FOREIGN KEY (usuario_id, categoria_id) REFERENCES categoria (usuario_id, id)
);

CREATE TABLE lancamento (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id uuid NOT NULL DEFAULT public.app_usuario_atual() REFERENCES usuario (id) ON DELETE CASCADE,
  tipo text NOT NULL CHECK (tipo IN ('gasto', 'entrada', 'transferencia', 'pagamento_fatura', 'estorno')),
  valor_centavos bigint NOT NULL CHECK (valor_centavos > 0),
  data_lancamento date NOT NULL,
  mes_competencia text NOT NULL CHECK (mes_competencia ~ '^\d{4}-(0[1-9]|1[0-2])$'),
  descricao text NOT NULL DEFAULT '' CHECK (length(descricao) <= 200),
  forma_pagamento text CHECK (forma_pagamento IN ('pix', 'debito', 'dinheiro', 'credito', 'pix_credito')),
  conta_id uuid,
  conta_destino_id uuid,
  cartao_id uuid,
  fatura_id uuid,
  categoria_id uuid,
  compra_parcelada_id uuid,
  parcela_numero smallint,
  parcela_total smallint,
  origem text NOT NULL CHECK (origem IN ('formulario', 'frase', 'importacao', 'arquivo')),
  removido_em timestamptz,
  criado_em timestamptz NOT NULL DEFAULT now(),
  atualizado_em timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (usuario_id, conta_id) REFERENCES conta (usuario_id, id),
  FOREIGN KEY (usuario_id, conta_destino_id) REFERENCES conta (usuario_id, id),
  FOREIGN KEY (usuario_id, cartao_id) REFERENCES cartao (usuario_id, id),
  FOREIGN KEY (usuario_id, fatura_id) REFERENCES fatura (usuario_id, id),
  FOREIGN KEY (usuario_id, categoria_id) REFERENCES categoria (usuario_id, id),
  FOREIGN KEY (usuario_id, compra_parcelada_id) REFERENCES compra_parcelada (usuario_id, id),
  -- Cada tipo tem o seu meio: gasto e estorno numa conta ou num cartão; entrada numa conta; transferência entre
  -- duas contas diferentes; pagamento de fatura de uma conta para um cartão.
  CONSTRAINT lancamento_meio_valido CHECK (
    (tipo IN ('gasto', 'estorno')
      AND (conta_id IS NULL) <> (cartao_id IS NULL)
      AND conta_destino_id IS NULL)
    OR (tipo = 'entrada'
      AND conta_id IS NOT NULL AND cartao_id IS NULL AND conta_destino_id IS NULL AND categoria_id IS NULL)
    OR (tipo = 'transferencia'
      AND conta_id IS NOT NULL AND conta_destino_id IS NOT NULL AND conta_id <> conta_destino_id
      AND cartao_id IS NULL AND categoria_id IS NULL)
    OR (tipo = 'pagamento_fatura'
      AND conta_id IS NOT NULL AND cartao_id IS NOT NULL AND conta_destino_id IS NULL AND categoria_id IS NULL)
  ),
  CONSTRAINT lancamento_fatura_so_no_cartao CHECK (
    fatura_id IS NULL OR (cartao_id IS NOT NULL AND tipo IN ('gasto', 'estorno'))
  ),
  CONSTRAINT lancamento_parcela_coerente CHECK (
    (compra_parcelada_id IS NULL AND parcela_numero IS NULL AND parcela_total IS NULL)
    OR (compra_parcelada_id IS NOT NULL
      AND parcela_total BETWEEN 2 AND 60
      AND parcela_numero BETWEEN 1 AND parcela_total)
  ),
  -- A forma de pagamento só existe em gasto e estorno, e combina com o meio: Pix, Débito e Dinheiro numa conta;
  -- Crédito e Pix no crédito num cartão.
  CONSTRAINT lancamento_forma_coerente CHECK (
    forma_pagamento IS NULL
    OR (tipo IN ('gasto', 'estorno') AND (
      (forma_pagamento IN ('pix', 'debito', 'dinheiro') AND conta_id IS NOT NULL)
      OR (forma_pagamento IN ('credito', 'pix_credito') AND cartao_id IS NOT NULL)))
  )
);
CREATE INDEX lancamento_mes_ativo ON lancamento (usuario_id, mes_competencia) WHERE removido_em IS NULL;
CREATE INDEX lancamento_da_compra ON lancamento (compra_parcelada_id) WHERE compra_parcelada_id IS NOT NULL;
CREATE INDEX lancamento_da_fatura ON lancamento (fatura_id) WHERE fatura_id IS NOT NULL;

CREATE TABLE evento_de_uso (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id uuid NOT NULL DEFAULT public.app_usuario_atual() REFERENCES usuario (id) ON DELETE CASCADE,
  tipo text NOT NULL CHECK (tipo IN ('lancamento', 'revisao', 'resposta_lembrete')),
  criado_em timestamptz NOT NULL DEFAULT now()
);

-- RLS nas tabelas com dado de usuário. Sem FORCE ROW LEVEL SECURITY: o dono (app_migrador) fica fora do RLS, e o
-- app_runtime, que não é dono, fica dentro. Quem garante isso é o teste dos privilégios.
DO $$
DECLARE
  tabela text;
BEGIN
  FOREACH tabela IN ARRAY ARRAY['instituicao', 'conta', 'cartao', 'categoria', 'fatura', 'compra_parcelada',
                               'lancamento', 'evento_de_uso'] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', tabela);
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_runtime') THEN
      EXECUTE format(
        'CREATE POLICY dados_do_usuario ON %I FOR ALL TO app_runtime
           USING (usuario_id = public.app_usuario_atual()) WITH CHECK (usuario_id = public.app_usuario_atual())',
        tabela);
    END IF;
  END LOOP;
END
$$;

-- Privilégios. Os privilégios padrão do núcleo já dão SELECT, INSERT, UPDATE e DELETE ao app_runtime nas tabelas
-- novas. Aqui só se tira o que sobra.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_runtime') THEN
    -- O app não troca o e-mail nem o id de ninguém.
    REVOKE INSERT, UPDATE ON usuario FROM app_runtime;
    GRANT INSERT (nome, email) ON usuario TO app_runtime;
    GRANT UPDATE (nome, email_verificado, atualizado_em) ON usuario TO app_runtime;
    REVOKE TRUNCATE ON ALL TABLES IN SCHEMA public FROM app_runtime;
    REVOKE CREATE ON SCHEMA public FROM app_runtime;
  END IF;
  REVOKE CREATE ON SCHEMA public FROM PUBLIC;
END
$$;
