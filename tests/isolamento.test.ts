import pg from 'pg'
import { beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { BANCO_DE_TESTE, conexao } from '../scripts/config.mjs'

/**
 * O teste central do repositório: o isolamento entre usuários feito pelo banco, com o papel real da aplicação
 * (app_runtime: sem superusuário, sem BYPASSRLS, sem posse de tabela). Roda no banco de teste já migrado
 * (`npm run migrar`), com dois usuários pequenos; não precisa da carga grande do estudo.
 */

const USUARIO_A = '0a0a0a0a-0000-4000-8000-00000000000a'
const USUARIO_B = '0b0b0b0b-0000-4000-8000-00000000000b'

const TABELAS_COM_RLS = [
  'instituicao',
  'conta',
  'cartao',
  'categoria',
  'fatura',
  'compra_parcelada',
  'lancamento',
  'evento_de_uso',
] as const
type TabelaComRls = (typeof TABELAS_COM_RLS)[number]
type Ids = Record<TabelaComRls, string>

/** Uma conexão nova, sem transação aberta. */
async function comConexao<T>(papel: 'app_runtime' | 'app_migrador', trabalho: (c: pg.Client) => Promise<T>): Promise<T> {
  const cliente = new pg.Client(conexao(papel, BANCO_DE_TESTE))
  await cliente.connect()
  try {
    return await trabalho(cliente)
  } finally {
    await cliente.end()
  }
}

/**
 * Uma transação como app_runtime, com o usuário marcado do jeito que a aplicação marca:
 * set_config('app.usuario_id', id, true), local à transação. Com null, a transação não marca ninguém.
 */
async function comUsuario<T>(usuarioId: string | null, trabalho: (c: pg.Client) => Promise<T>): Promise<T> {
  return comConexao('app_runtime', async (c) => {
    await c.query('BEGIN')
    try {
      if (usuarioId !== null) await c.query("SELECT set_config('app.usuario_id', $1, true)", [usuarioId])
      const resultado = await trabalho(c)
      await c.query('COMMIT')
      return resultado
    } catch (erro) {
      await c.query('ROLLBACK').catch(() => undefined)
      throw erro
    }
  })
}

async function inserir(c: pg.Client, sql: string, parametros: unknown[] = []): Promise<string> {
  const id = (await c.query<{ id: string }>(sql, parametros)).rows[0]?.id
  if (!id) throw new Error('A inserção não devolveu o id.')
  return id
}

/** Uma linha em cada tabela com RLS, do usuário marcado. O usuario_id vem do DEFAULT app_usuario_atual(). */
async function semear(usuarioId: string): Promise<Ids> {
  return comUsuario(usuarioId, async (c) => {
    const instituicao = await inserir(c, "INSERT INTO instituicao (nome) VALUES ('Banco Fictício') RETURNING id")
    const conta = await inserir(c, "INSERT INTO conta (nome, tipo, instituicao_id) VALUES ('Corrente', 'corrente', $1) RETURNING id", [instituicao])
    const cartao = await inserir(c, "INSERT INTO cartao (nome, dia_fechamento, dia_vencimento) VALUES ('Cartão', 25, 5) RETURNING id")
    const categoria = await inserir(c, "INSERT INTO categoria (nome) VALUES ('Mercado') RETURNING id")
    const fatura = await inserir(
      c,
      "INSERT INTO fatura (cartao_id, mes_referencia, data_fechamento, data_vencimento) VALUES ($1, '2026-10', '2026-09-25', '2026-10-05') RETURNING id",
      [cartao],
    )
    const compra = await inserir(
      c,
      "INSERT INTO compra_parcelada (cartao_id, valor_total_centavos, parcelas, data_compra) VALUES ($1, 60000, 3, '2026-09-20') RETURNING id",
      [cartao],
    )
    const lancamento = await inserir(
      c,
      `INSERT INTO lancamento (tipo, valor_centavos, data_lancamento, mes_competencia, conta_id, categoria_id, forma_pagamento, origem)
       VALUES ('gasto', 3250, '2026-09-27', '2026-09', $1, $2, 'pix', 'formulario') RETURNING id`,
      [conta, categoria],
    )
    const evento = await inserir(c, "INSERT INTO evento_de_uso (tipo) VALUES ('lancamento') RETURNING id")
    return { instituicao, conta, cartao, categoria, fatura, compra_parcelada: compra, lancamento, evento_de_uso: evento }
  })
}

async function idsVisiveis(usuarioId: string, tabela: TabelaComRls): Promise<string[]> {
  return comUsuario(usuarioId, async (c) => {
    const r = await c.query<{ id: string }>(`SELECT id FROM ${c.escapeIdentifier(tabela)} ORDER BY id`)
    return r.rows.map((l) => l.id)
  })
}

/**
 * Uma inserção válida em cada tabela, exceto pelo usuario_id, que é o de outra pessoa ($1). As referências usam ids
 * dessa outra pessoa, para a chave composta passar: a única razão de falhar é o WITH CHECK do RLS.
 */
function insercaoComUsuarioAlheio(tabela: TabelaComRls, doOutro: Ids): { sql: string; parametros: unknown[] } {
  switch (tabela) {
    case 'instituicao':
      return { sql: "INSERT INTO instituicao (usuario_id, nome) VALUES ($1, 'Intrusa')", parametros: [] }
    case 'conta':
      return { sql: "INSERT INTO conta (usuario_id, nome, tipo) VALUES ($1, 'Intrusa', 'corrente')", parametros: [] }
    case 'cartao':
      return { sql: "INSERT INTO cartao (usuario_id, nome, dia_fechamento, dia_vencimento) VALUES ($1, 'Intrusa', 25, 5)", parametros: [] }
    case 'categoria':
      return { sql: "INSERT INTO categoria (usuario_id, nome) VALUES ($1, 'Intrusa')", parametros: [] }
    case 'fatura':
      return {
        sql: `INSERT INTO fatura (usuario_id, cartao_id, mes_referencia, data_fechamento, data_vencimento)
              VALUES ($1, $2, '2026-12', '2026-11-25', '2026-12-05')`,
        parametros: [doOutro.cartao],
      }
    case 'compra_parcelada':
      return {
        sql: `INSERT INTO compra_parcelada (usuario_id, cartao_id, valor_total_centavos, parcelas, data_compra)
              VALUES ($1, $2, 1000, 2, '2026-09-01')`,
        parametros: [doOutro.cartao],
      }
    case 'lancamento':
      return {
        sql: `INSERT INTO lancamento (usuario_id, tipo, valor_centavos, data_lancamento, mes_competencia, conta_id, origem)
              VALUES ($1, 'entrada', 100, '2026-09-27', '2026-09', $2, 'formulario')`,
        parametros: [doOutro.conta],
      }
    case 'evento_de_uso':
      return { sql: "INSERT INTO evento_de_uso (usuario_id, tipo) VALUES ($1, 'lancamento')", parametros: [] }
  }
}

let deA: Ids
let deB: Ids

beforeAll(() => {
  if (!BANCO_DE_TESTE.endsWith('_teste')) throw new Error('Os testes só rodam num banco cujo nome termina em _teste.')
})

beforeEach(async () => {
  // Como app_migrador, dono das tabelas (fora do RLS): apaga tudo e regrava os dois usuários.
  await comConexao('app_migrador', async (c) => {
    await c.query('TRUNCATE usuario CASCADE')
    await c.query("INSERT INTO usuario (id, nome, email) VALUES ($1, 'Pessoa A', 'pessoa.a@exemplo.test'), ($2, 'Pessoa B', 'pessoa.b@exemplo.test')", [
      USUARIO_A,
      USUARIO_B,
    ])
  })
  deA = await semear(USUARIO_A)
  deB = await semear(USUARIO_B)
})

describe('o papel da aplicação está sujeito ao RLS', () => {
  it('app_runtime não é superusuário, não tem BYPASSRLS, não é dono de nada e não herda outro papel', async () => {
    const estado = await comConexao('app_runtime', async (c) => {
      const r = await c.query(
        `SELECT current_user AS papel,
                r.rolsuper AS superusuario,
                r.rolbypassrls AS ignora_rls,
                EXISTS (SELECT 1 FROM pg_class k JOIN pg_namespace n ON n.oid = k.relnamespace
                         WHERE n.nspname = 'public' AND k.relowner = r.oid) AS dono_de_objeto,
                EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                         WHERE n.nspname = 'public' AND p.proowner = r.oid) AS dono_de_funcao,
                EXISTS (SELECT 1 FROM pg_auth_members m WHERE m.member = r.oid) AS membro_de_outro_papel
           FROM pg_roles r WHERE r.rolname = current_user`,
      )
      return r.rows[0]
    })
    expect(estado).toEqual({
      papel: 'app_runtime',
      superusuario: false,
      ignora_rls: false,
      dono_de_objeto: false,
      dono_de_funcao: false,
      membro_de_outro_papel: false,
    })
  })

  it('toda tabela com usuario_id tem RLS ligado e a política dados_do_usuario para app_runtime', async () => {
    const tabelas = await comConexao('app_runtime', async (c) => {
      const r = await c.query<{ tabela: string; rls: boolean; politicas: number }>(
        `SELECT k.relname AS tabela, k.relrowsecurity AS rls,
                (SELECT count(*)::int FROM pg_policies p
                  WHERE p.schemaname = 'public' AND p.tablename = k.relname
                    AND p.policyname = 'dados_do_usuario' AND 'app_runtime' = ANY (p.roles)) AS politicas
           FROM pg_class k JOIN pg_namespace n ON n.oid = k.relnamespace
          WHERE n.nspname = 'public' AND k.relkind = 'r'
            AND EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = k.oid AND a.attname = 'usuario_id' AND NOT a.attisdropped)
          ORDER BY 1`,
      )
      return r.rows
    })
    expect(tabelas.map((t) => t.tabela)).toEqual([...TABELAS_COM_RLS].sort())
    for (const t of tabelas) expect(t, t.tabela).toEqual({ tabela: t.tabela, rls: true, politicas: 1 })
  })

  it('app_runtime não cria tabela, não esvazia tabela e não mexe no registro de migrações', async () => {
    await expect(comConexao('app_runtime', (c) => c.query('CREATE TABLE intrusa (id int)'))).rejects.toThrow(/permission denied/)
    await expect(comConexao('app_runtime', (c) => c.query('TRUNCATE lancamento'))).rejects.toThrow(/permission denied/)
    await expect(comConexao('app_runtime', (c) => c.query('DELETE FROM migracao'))).rejects.toThrow(/permission denied/)
  })
})

describe('isolamento entre usuários', () => {
  it('A lê só as próprias linhas, em toda tabela com RLS, e não acha a linha de B nem pelo id', async () => {
    for (const tabela of TABELAS_COM_RLS) {
      expect(await idsVisiveis(USUARIO_A, tabela), tabela).toEqual([deA[tabela]])
      expect(await idsVisiveis(USUARIO_B, tabela), tabela).toEqual([deB[tabela]])
      const pelaChave = await comUsuario(USUARIO_A, (c) =>
        c.query(`SELECT 1 FROM ${c.escapeIdentifier(tabela)} WHERE id = $1`, [deB[tabela]]),
      )
      expect(pelaChave.rowCount, tabela).toBe(0)
    }
  })

  it('A não altera nem apaga as linhas de B, nem as move para si trocando o usuario_id', async () => {
    for (const tabela of TABELAS_COM_RLS) {
      const mudou = await comUsuario(USUARIO_A, (c) =>
        c.query(`UPDATE ${c.escapeIdentifier(tabela)} SET usuario_id = $1 WHERE id = $2`, [USUARIO_A, deB[tabela]]),
      )
      expect(mudou.rowCount, tabela).toBe(0)
    }
    for (const tabela of [...TABELAS_COM_RLS].reverse()) {
      const apagou = await comUsuario(USUARIO_A, (c) => c.query(`DELETE FROM ${c.escapeIdentifier(tabela)} WHERE id = $1`, [deB[tabela]]))
      expect(apagou.rowCount, tabela).toBe(0)
    }
    for (const tabela of TABELAS_COM_RLS) {
      expect(await idsVisiveis(USUARIO_B, tabela), tabela).toEqual([deB[tabela]])
    }
  })

  it('A não grava uma linha com o usuario_id de B, nem passa uma linha sua para B', async () => {
    for (const tabela of TABELAS_COM_RLS) {
      const { sql, parametros } = insercaoComUsuarioAlheio(tabela, deB)
      await expect(comUsuario(USUARIO_A, (c) => c.query(sql, [USUARIO_B, ...parametros])), tabela).rejects.toThrow(
        /row-level security/,
      )
    }
    await expect(
      comUsuario(USUARIO_A, (c) => c.query('UPDATE categoria SET usuario_id = $1 WHERE id = $2', [USUARIO_B, deA.categoria])),
    ).rejects.toThrow(/row-level security/)
  })

  it('A não aponta uma chave estrangeira para a linha de B (a conferência de FK ignora o RLS; a chave composta não)', async () => {
    const tentativas: Array<[string, (c: pg.Client) => Promise<unknown>]> = [
      [
        'conta',
        (c) =>
          c.query(
            `INSERT INTO lancamento (tipo, valor_centavos, data_lancamento, mes_competencia, conta_id, origem)
             VALUES ('gasto', 100, '2026-09-27', '2026-09', $1, 'formulario')`,
            [deB.conta],
          ),
      ],
      [
        'cartao',
        (c) =>
          c.query(
            `INSERT INTO lancamento (tipo, valor_centavos, data_lancamento, mes_competencia, cartao_id, origem)
             VALUES ('gasto', 100, '2026-09-27', '2026-09', $1, 'formulario')`,
            [deB.cartao],
          ),
      ],
      [
        'categoria',
        (c) =>
          c.query(
            `INSERT INTO lancamento (tipo, valor_centavos, data_lancamento, mes_competencia, conta_id, categoria_id, origem)
             VALUES ('gasto', 100, '2026-09-27', '2026-09', $1, $2, 'formulario')`,
            [deA.conta, deB.categoria],
          ),
      ],
      [
        'fatura',
        (c) =>
          c.query(
            `INSERT INTO lancamento (tipo, valor_centavos, data_lancamento, mes_competencia, cartao_id, fatura_id, origem)
             VALUES ('gasto', 100, '2026-09-27', '2026-09', $1, $2, 'formulario')`,
            [deA.cartao, deB.fatura],
          ),
      ],
      [
        'compra_parcelada',
        (c) =>
          c.query(
            `INSERT INTO lancamento (tipo, valor_centavos, data_lancamento, mes_competencia, cartao_id,
                                     compra_parcelada_id, parcela_numero, parcela_total, origem)
             VALUES ('gasto', 100, '2026-09-27', '2026-09', $1, $2, 1, 3, 'formulario')`,
            [deA.cartao, deB.compra_parcelada],
          ),
      ],
      ['instituicao', (c) => c.query("INSERT INTO conta (nome, tipo, instituicao_id) VALUES ('Minha', 'corrente', $1)", [deB.instituicao])],
      [
        'cartao da fatura',
        (c) =>
          c.query(
            `INSERT INTO fatura (cartao_id, mes_referencia, data_fechamento, data_vencimento)
             VALUES ($1, '2027-01', '2026-12-25', '2027-01-05')`,
            [deB.cartao],
          ),
      ],
      [
        'apontar uma linha existente (UPDATE)',
        (c) => c.query('UPDATE lancamento SET categoria_id = $1 WHERE id = $2', [deB.categoria, deA.lancamento]),
      ],
    ]
    for (const [nome, tentativa] of tentativas) {
      await expect(comUsuario(USUARIO_A, tentativa), nome).rejects.toThrow(/violates foreign key constraint/)
    }
  })

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

  it('a marca vale só na transação: a mesma conexão, numa transação seguinte sem marca, não lê nada', async () => {
    await comConexao('app_runtime', async (c) => {
      await c.query('BEGIN')
      await c.query("SELECT set_config('app.usuario_id', $1, true)", [USUARIO_A])
      expect((await c.query('SELECT id FROM lancamento')).rowCount).toBe(1)
      await c.query('COMMIT')
      await expect(c.query('SELECT id FROM lancamento')).rejects.toThrow(/app_usuario_ausente/)
    })
  })
})

describe('a fronteira: o banco confia na marca que a aplicação põe', () => {
  it('a marca não prova identidade: quem marca o id de B, com o papel do app, lê os dados de B', async () => {
    // Não é falha do RLS, é o limite dele: o banco separa os dados pelo valor marcado na transação, e quem marca é a
    // aplicação, depois de autenticar a pessoa. SQL arbitrário com o papel do app pode marcar qualquer id.
    const visto = await comConexao('app_runtime', async (c) => {
      await c.query('BEGIN')
      await c.query("SELECT set_config('app.usuario_id', $1, true)", [USUARIO_A])
      await c.query("SELECT set_config('app.usuario_id', $1, true)", [USUARIO_B])
      const r = await c.query<{ id: string }>('SELECT id FROM lancamento')
      await c.query('ROLLBACK')
      return r.rows.map((l) => l.id)
    })
    expect(visto).toEqual([deB.lancamento])
  })
})
