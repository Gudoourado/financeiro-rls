# ADR 0025 — Separar os dados por usuário com `usuario_id`, RLS, chaves estrangeiras compostas e privilégios testados

- Status: aceita
- Data: 2026-09-27
- Versão pública: higienizada a partir do ADR do app original (sem nomes de serviços, planos internos nem
  referências a outros ADRs que não estão neste repositório).

## Contexto

- O app deixou de ser de um usuário só: um grupo pequeno de pessoas usa a mesma instância, cada uma com as próprias
  finanças, no mesmo banco.
- Regra do projeto: o isolamento entre usuários vence qualquer outra prioridade.
- Fatos do PostgreSQL que moldam a decisão:
  - com um pooler em modo de transação, configuração de sessão vaza entre requisições; configuração local da
    transação (`set_config(..., true)`) não vaza;
  - o RLS não se aplica à conferência de chave estrangeira;
  - dono da tabela, superusuário e papel com `BYPASSRLS` ignoram o RLS;
  - o `pg_dump` falha em tabela com RLS, a menos que o papel ignore o RLS ou rode com `--enable-row-security` e
    tenha uma política de leitura.
- Pontos levantados em revisão do desenho:
  - o desenho com RLS, `set_config` local e chaves compostas está certo;
  - falta provar os privilégios, não só as políticas: dono, `BYPASSRLS`, herança de papéis e `CREATE` no schema;
  - o RLS protege contra consulta que esquece o usuário, não contra SQL arbitrário executado com o papel do app.

## Alternativas consideradas

1. **Só um filtro `WHERE usuario_id = $1` na aplicação.** Descartada: um único filtro esquecido numa consulta nova
   vaza os dados de uma pessoa para outra, e não há segunda barreira.
2. **Um banco por pessoa.** Descartada: um banco para migrar, fazer backup e manter por pessoa.
3. **RLS sem chave estrangeira composta.** Descartada: como a conferência de chave estrangeira ignora o RLS, um
   usuário que soubesse um id conseguiria apontar um lançamento dele para a conta de outra pessoa.
4. **`FORCE ROW LEVEL SECURITY`.** Descartada: o migrador e as ferramentas de administração precisam agir fora do
   RLS. O papel do app não é dono das tabelas, então o RLS já vale para ele. O que garante isso é o teste de
   privilégios, não o `FORCE`.

## Decisão

**Coluna e marcação do usuário**
- Toda tabela com dado financeiro ou pessoal de um usuário tem
  `usuario_id uuid NOT NULL DEFAULT public.app_usuario_atual() REFERENCES usuario (id) ON DELETE CASCADE`.
- A unidade de trabalho do app abre a transação e, se houver um usuário autenticado, roda
  `SELECT set_config('app.usuario_id', $1, true)` antes de qualquer consulta.
- `public.app_usuario_atual()` é pequena, `STABLE` e `SECURITY INVOKER`, com nomes qualificados pelo schema. Dá o
  erro `app_usuario_ausente` se o valor estiver ausente ou vazio. Sem usuário marcado, ler, inserir, mudar ou
  apagar numa tabela com RLS falha.
- Os repositórios não recebem `usuario_id` de fora: no `INSERT`, ele vem do `DEFAULT`; na leitura, quem filtra é o
  RLS.

**Políticas**
- Em cada tabela com dado de usuário: `ENABLE ROW LEVEL SECURITY` e a política `dados_do_usuario`,
  `FOR ALL TO app_runtime`, com `USING` e `WITH CHECK` iguais a `usuario_id = public.app_usuario_atual()`.
- No app original há ainda políticas só de leitura para um papel de backup e um de demonstração; elas não estão
  neste repositório.

**Chaves e unicidade**
- Toda referência entre tabelas com `usuario_id` leva o `usuario_id` junto
  (`FOREIGN KEY (usuario_id, conta_id) REFERENCES conta (usuario_id, id)`), com `UNIQUE (usuario_id, id)` na
  tabela apontada.
- Nomes únicos por pessoa, sem diferenciar maiúsculas: `(usuario_id, lower(nome))`.

**Privilégios, tratados como regra testada**
- `app_migrador` é dono de todas as tabelas, funções e sequências.
- `app_runtime` não é dono de nada, não tem `BYPASSRLS`, não é membro de outro papel, não tem `TRUNCATE` e não cria
  objetos no schema `public`.
- Nas tabelas de sistema, sem RLS, `app_runtime` só tem o que o código usa.
- Na subida, o app confere o papel da conexão e não sobe se ele puder ignorar o RLS (superusuário, `BYPASSRLS`,
  dono de tabela ou membro de outro papel).

**Migração:** a migração `multiusuario` recria as tabelas do núcleo com `usuario_id`. Ela só roda com essas tabelas
vazias.

**Testes, escritos antes do código:**
- dois usuários, A e B: A não lê, não muda e não aponta para nada de B, em toda tabela com RLS;
- sem usuário marcado, a consulta dá erro;
- uma conexão reaproveitada não carrega o usuário anterior;
- toda tabela com `usuario_id` tem RLS e a política;
- os privilégios acima, lidos do catálogo do PostgreSQL.

## Consequências

- Fica mais fácil:
  - uma consulta que esquece o usuário dá erro, em vez de vazar;
  - o isolamento é testável direto no banco;
  - excluir uma conta é apagar uma linha, e a cascata leva o resto.
- Fica mais difícil:
  - toda consulta de dado pessoal precisa de transação com o `set_config` no começo;
  - toda tabela nova precisa de `usuario_id`, política e chave composta (o teste do catálogo cobra);
  - depurar num console SQL exige marcar o usuário antes.
- O RLS não protege contra SQL arbitrário executado com `app_runtime`, que poderia trocar o `app.usuario_id`. Por
  isso, SQL só com parâmetros continua sendo regra, e a marca só é posta depois da autenticação.

## Como saber que erramos

- O teste de isolamento, o do catálogo ou o de privilégios é desligado "para destravar" uma entrega.
- Uma pessoa vê, em qualquer tela ou rota, um dado que não é dela.
- A abertura da unidade de trabalho passa a custar mais de 50 ms nas telas.
