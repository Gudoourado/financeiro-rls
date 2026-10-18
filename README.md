# financeiro-rls

Isolamento de dados por usuário no PostgreSQL 17 com Row-Level Security (RLS), testado com o papel real da
aplicação, e um estudo de desempenho de três consultas de um app de finanças pessoais sob esse RLS.

Extraído de um app real e higienizado. O que tem aqui:

- **`tests/isolamento.test.ts`**: a peça central. Prova, contra um PostgreSQL de verdade e com o papel que a
  aplicação usa, que um usuário não lê, não altera, não apaga e não referencia os dados de outro.
- **`migrations/`**: o esquema (núcleo, multiusuário com RLS e chaves compostas, e o índice que o estudo recomendou).
- **`estudo/`** e **`docs/relatorio.md`**: o estudo de desempenho, com o método, os números e o resultado ruim que
  levou a descartar uma otimização.
- **`docs/adr-0025-rls-por-usuario.md`**: a decisão de arquitetura.

## Rodar os testes (cerca de 1 minuto, sem a carga grande)

Requisitos: Docker com Compose e Node 24.

```bash
cp .env.example .env          # troque as senhas; o .env fica fora do git
docker compose up -d --wait   # PostgreSQL 17 só deste repositório, em 127.0.0.1:55433
npm ci
npm run migrar                # papéis, banco rls_teste e as 3 migrações
npm test
```

Saída esperada: `Tests  10 passed (10)`. Para desligar e apagar o volume: `docker compose down -v`.

O compose usa o nome de projeto `financeiro-rls` e abre a porta só no `127.0.0.1` (mude `POSTGRES_PORTA` no
`.env` se ela estiver ocupada).

## O que o teste de isolamento cobre

Tudo roda como **`app_runtime`**, o papel da aplicação, em transações com o usuário marcado do jeito que a
aplicação marca. Dois usuários, A e B, cada um com uma linha em cada uma das 8 tabelas com RLS.

| Teste | O que prova |
|---|---|
| O papel não é superusuário, não tem `BYPASSRLS`, não é dono de nada e não herda outro papel | O RLS vale para ele. Superusuário, `BYPASSRLS` e dono da tabela passam por cima do RLS (as tabelas não usam `FORCE ROW LEVEL SECURITY`) |
| Toda tabela com `usuario_id` tem RLS ligado e a política `dados_do_usuario` | Uma tabela nova sem política reprova |
| O papel não cria tabela, não esvazia tabela e não mexe no registro de migrações | Privilégio mínimo |
| A lê só as próprias linhas, e não acha a linha de B nem pelo id | Leitura isolada |
| A não altera nem apaga as linhas de B, nem as move para si | `USING` em `UPDATE` e `DELETE` |
| A não grava linha com o `usuario_id` de B, nem passa uma linha sua para B | `WITH CHECK` |
| A não aponta uma chave estrangeira para a linha de B | A conferência de FK **ignora o RLS**; quem barra são as FKs compostas `(usuario_id, x_id)` |
| Sem usuário marcado, o banco recusa ler, inserir, alterar e apagar | Falha fechada: erro `app_usuario_ausente`, nunca "zero linhas" silencioso |
| A marca vale só na transação | Uma conexão reaproveitada de um pool não carrega o usuário anterior |
| A marca não prova identidade | O limite do RLS (veja abaixo) |

Para conferir que o teste não passa por acaso: `ALTER ROLE app_runtime BYPASSRLS` (como `postgres`) faz 7 dos 10
testes falharem; o de FK continua passando, porque não depende do RLS.

## A fronteira: o que o banco garante e o que depende da aplicação

```sql
-- migrations/02_multiusuario.sql
CREATE FUNCTION public.app_usuario_atual() RETURNS uuid
  LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = pg_catalog, pg_temp
AS $$ ... current_setting('app.usuario_id', true) ... RAISE EXCEPTION 'app_usuario_ausente' ... $$;

CREATE POLICY dados_do_usuario ON lancamento FOR ALL TO app_runtime
  USING (usuario_id = public.app_usuario_atual()) WITH CHECK (usuario_id = public.app_usuario_atual());
```

- `app_usuario_atual()` só lê uma **configuração da transação**. A aplicação a define, depois de autenticar a
  pessoa, no começo de cada transação: `BEGIN; SELECT set_config('app.usuario_id', $1, true); ...`. O `true` torna
  a configuração local à transação, então ela some no `COMMIT` e não vaza para a próxima requisição que pegar a
  mesma conexão do pool.
- **O banco depende de a aplicação marcar o usuário certo.** Uma configuração de sessão não é prova de identidade:
  quem tem o papel do app e consegue executar SQL arbitrário pode marcar qualquer id e ler os dados dessa pessoa.
  O teste "a marca não prova identidade" mostra isso de propósito. O RLS protege contra a consulta que **esquece**
  o filtro de usuário, não contra SQL injetado. Por isso a aplicação só usa SQL com parâmetros.
- **Sem marca, nada passa.** O teste sem contexto, em `tests/isolamento.test.ts`:

  ```ts
  it('sem usuário marcado, o banco recusa ler, inserir, alterar e apagar', async () => {
    const comandos = [
      'SELECT count(*) FROM lancamento',
      "INSERT INTO categoria (nome) VALUES ('Sem dono')",
      "UPDATE categoria SET nome = 'Outro'",
      'DELETE FROM categoria',
    ]
    for (const sql of comandos) {
      await expect(comUsuario(null, (c) => c.query(sql)), sql).rejects.toThrow(/app_usuario_ausente/)
    }
  })
  ```

- **O papel tem que estar sujeito ao RLS.** Se a aplicação conectar como superusuário, como dono das tabelas ou
  com `BYPASSRLS`, as políticas não valem. O app confere isso na subida e não sobe se o papel puder ignorar o RLS;
  a mesma checagem está em `scripts/verificar-papel.mjs` (`npm run verificar-papel`).
- `app_migrador` é o dono das tabelas e fica fora do RLS de propósito: ele aplica as migrações e gera a carga do
  estudo. A aplicação nunca usa esse papel.

## O estudo de desempenho

Relatório completo: [`docs/relatorio.md`](docs/relatorio.md). Resumo, **nestas consultas, com esta carga e este
ambiente**:

| Achado | Antes | Depois | Decisão |
|---|---|---|---|
| Q3 (último meio de gasto), usuário com 120 mil lançamentos, com índice parcial `(usuario_id, criado_em DESC, id DESC) WHERE removido_em IS NULL` | 325 a 335 ms (lê 116.283 linhas) | 0,09 a 0,10 ms (lê 1 linha) | Adotado (`migrations/03_ultimo_meio_de_gasto.sql`) |
| Q2 (faturas), mesmo usuário, política reescrita com `(SELECT app_usuario_atual())` (initPlan) | ~8 ms | **74 a 87 ms** | **Descartado**: o planejador deixa de ver o usuário e escolhe o plano do "usuário médio" |
| Q1 (lançamentos do mês) | 6 a 7 ms no pesado, < 0,4 ms nos outros | sem mudança | O RLS usa o índice; custo dentro do ruído |
| Isolamento no banco grande, antes e depois das mudanças | 49 de 49 conferências | 49 de 49 | A otimização não quebra o isolamento |

Planos de execução publicados em `resultados/planos/`:

| Arquivo | O que mostra |
|---|---|
| `r1_A_q3_pesado.txt` | Q3 sem o índice: Sort top-N sobre 116 mil linhas |
| `r1_C_q3_pesado.txt` | Q3 com o índice parcial: Index Scan + Limit, 4 páginas |
| `r1_REF_A_q3_pesado.txt` | Q3 sem RLS (superusuário, filtro explícito), antes do índice: mesmo plano e mesmo tempo que com RLS |
| `r1_A_q2_pesado.txt` | Q2 com a política chamando a função direto |
| `r1_B_q2_pesado.txt` | Q2 com o initPlan: estimativa de 6.750 linhas, real de 116.283, em 4 loops |
| `r1_REF_A_q2_pesado.txt` | Q2 sem RLS (referência) |

O resumo das 108 séries está em `resultados/resumo.txt`.

### Método

- **PostgreSQL 17.11**, imagem oficial `postgres:17`, configuração padrão da imagem: `shared_buffers` 128MB,
  `work_mem` 4MB, `effective_cache_size` 4GB, `random_page_cost` 4, `jit` on,
  `max_parallel_workers_per_gather` 2.
- **Máquina:** notebook com CPU de 4 núcleos e 8 threads e 13,7 GB de RAM visíveis ao sistema, Windows 11, Docker
  Desktop com VM WSL2 (8 CPUs, ~5,8 GB para a VM). Outros contêineres ociosos ligados.
- **Carga:** 1.393.270 lançamentos fictícios de 200 usuários, com distribuição por lei de potência (o maior tem
  120 mil), gerados com semente fixa (`setseed(0.27)`). Perfis medidos: pesado, mediano e leve.
- **`ANALYZE` antes:** `VACUUM (ANALYZE)` depois da carga e `ANALYZE` a cada troca de índices.
- **Repetições:** 1 aquecimento + 30 medições por série; mediana e p95 do `Execution Time`. O roteiro inteiro rodou
  duas vezes seguidas, e só contam as diferenças grandes e repetidas nas duas rodadas.
- **Cache:** quente no sistema operacional (a tabela cabe no cache de páginas da VM), mas não nos 128 MB de
  `shared_buffers`. Não houve medição com cache frio.
- **Papel:** `app_runtime` com `set_config` na transação, como a aplicação. A referência sem RLS roda como
  superusuário com o filtro explícito.
- **Instrumentação:** o `EXPLAIN ANALYZE` tem custo de instrumentação e **não mede o envio das linhas ao cliente**
  nem a rede. Para o usuário pesado, cada série também rodou no `pgbench` (sem EXPLAIN, latência medida no
  cliente, dentro do contêiner), que confirmou a direção e a ordem de grandeza de todos os achados.
- **Limites:** uma consulta por vez (sem concorrência), escritas não medidas, dados sintéticos, um mês só, valores
  passados como literais. Os números absolutos não valem para outra máquina ou para um servidor com rede; a
  direção dos efeitos, sim.

### Reproduzir o estudo (cerca de 15 minutos)

Com o compose no ar e o `npm run migrar` feito (os papéis precisam existir):

```bash
bash estudo/01_preparar.sh      # banco estudo_rls, separado do de teste; a carga leva ~4 min
bash estudo/00_rodar_tudo.sh    # 2 rodadas x 6 cenários x 3 consultas x 3 perfis, mais o isolamento
node estudo/08_resumir.mjs      # tabela em estudo/saidas/08_resumo.txt
npm run estudo:apagar           # apaga o banco do estudo
```

Para uma passada rápida, só para ver os scripts funcionando: `RODADAS=1 MEDICOES=5 bash estudo/00_rodar_tudo.sh`.
As saídas vão para `estudo/saidas/` (fora do git); os números publicados ficam em `resultados/`.

## Estrutura

```
compose.yaml, .env.example     PostgreSQL 17 local, senhas no .env
papeis/papeis.sql              app_migrador (dono) e app_runtime (o papel do app)
migrations/                    01 núcleo, 02 multiusuário com RLS, 03 índice do estudo
scripts/migrar.mjs             cria papéis e banco e aplica as migrações, uma por transação
scripts/verificar-papel.mjs    a guarda de subida: recusa papel que ignora o RLS
tests/isolamento.test.ts       o teste central
estudo/                        carga, consultas, cenários, medição, contagem de chamadas, isolamento, resumo
resultados/                    os números publicados: resumo, planos, chamadas da função, isolamento
docs/                          relatório do estudo e ADR
```
