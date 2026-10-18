-- Núcleo do app quando ele ainda era de um usuário só. A migração 02 recria estas tabelas com usuario_id e RLS;
-- esta fica aqui para o histórico de migrações ser o mesmo que o estudo usou.
-- Roda como app_migrador, que fica dono das tabelas.

CREATE TABLE instituicao (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nome text NOT NULL UNIQUE CHECK (length(nome) BETWEEN 1 AND 80),
  criado_em timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE conta (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  instituicao_id uuid REFERENCES instituicao (id),
  nome text NOT NULL CHECK (length(nome) BETWEEN 1 AND 80),
  tipo text NOT NULL CHECK (tipo IN ('corrente', 'poupanca', 'dinheiro')),
  criado_em timestamptz NOT NULL DEFAULT now(),
  UNIQUE NULLS NOT DISTINCT (instituicao_id, nome)
);

CREATE TABLE cartao (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  instituicao_id uuid REFERENCES instituicao (id),
  nome text NOT NULL CHECK (length(nome) BETWEEN 1 AND 80),
  dia_fechamento smallint NOT NULL CHECK (dia_fechamento BETWEEN 1 AND 31),
  dia_vencimento smallint NOT NULL CHECK (dia_vencimento BETWEEN 1 AND 31),
  criado_em timestamptz NOT NULL DEFAULT now(),
  UNIQUE NULLS NOT DISTINCT (instituicao_id, nome)
);

CREATE TABLE categoria (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nome text NOT NULL UNIQUE CHECK (length(nome) BETWEEN 1 AND 60),
  criado_em timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE fatura (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cartao_id uuid NOT NULL REFERENCES cartao (id),
  mes_referencia text NOT NULL CHECK (mes_referencia ~ '^\d{4}-(0[1-9]|1[0-2])$'),
  data_fechamento date NOT NULL,
  data_vencimento date NOT NULL,
  criado_em timestamptz NOT NULL DEFAULT now(),
  CHECK (data_vencimento > data_fechamento),
  UNIQUE (cartao_id, mes_referencia)
);

CREATE TABLE compra_parcelada (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cartao_id uuid NOT NULL REFERENCES cartao (id),
  categoria_id uuid REFERENCES categoria (id),
  descricao text NOT NULL DEFAULT '' CHECK (length(descricao) <= 200),
  valor_total_centavos bigint NOT NULL CHECK (valor_total_centavos > 0),
  parcelas smallint NOT NULL CHECK (parcelas BETWEEN 2 AND 60),
  data_compra date NOT NULL,
  removido_em timestamptz,
  criado_em timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE lancamento (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tipo text NOT NULL CHECK (tipo IN ('gasto', 'entrada', 'transferencia', 'pagamento_fatura', 'estorno')),
  valor_centavos bigint NOT NULL CHECK (valor_centavos > 0),
  data_lancamento date NOT NULL,
  mes_competencia text NOT NULL CHECK (mes_competencia ~ '^\d{4}-(0[1-9]|1[0-2])$'),
  descricao text NOT NULL DEFAULT '' CHECK (length(descricao) <= 200),
  conta_id uuid REFERENCES conta (id),
  conta_destino_id uuid REFERENCES conta (id),
  cartao_id uuid REFERENCES cartao (id),
  fatura_id uuid REFERENCES fatura (id),
  categoria_id uuid REFERENCES categoria (id),
  compra_parcelada_id uuid REFERENCES compra_parcelada (id),
  parcela_numero smallint,
  parcela_total smallint,
  origem text NOT NULL CHECK (origem IN ('formulario', 'frase', 'importacao', 'arquivo')),
  removido_em timestamptz,
  criado_em timestamptz NOT NULL DEFAULT now(),
  atualizado_em timestamptz NOT NULL DEFAULT now(),
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
  )
);

CREATE INDEX lancamento_mes_ativo ON lancamento (mes_competencia) WHERE removido_em IS NULL;
CREATE INDEX lancamento_da_compra ON lancamento (compra_parcelada_id) WHERE compra_parcelada_id IS NOT NULL;

-- Privilégios. Esta migração roda como app_migrador, dono das tabelas; os privilégios padrão valem para as tabelas
-- que ele criar depois. O app_runtime lê e grava dados, mas não mexe no registro de migrações.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_runtime') THEN
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_runtime;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_runtime;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO app_runtime;
    REVOKE INSERT, UPDATE, DELETE ON migracao FROM app_runtime;
  END IF;
END
$$;
