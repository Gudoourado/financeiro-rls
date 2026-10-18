// Confere o isolamento no banco grande do estudo, no estado em que ele estiver (o 00_rodar_tudo.sh roda isto no
// estado A e no D): leitura e escrita entre dois usuários novos (a mesma ideia dos primeiros casos de
// tests/isolamento.test.ts), a gravação com o usuario_id alheio, a falha fechada sem marca e uma conferência em
// volume. Cada passo é uma transação do app_runtime com o usuário marcado por set_config.
// Uso: node 07_isolamento.mjs <rotulo>   (grava estudo/saidas/07_isolamento_<rotulo>.txt)
import { mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { idsDosPerfis, psql } from './04_medir.mjs'
import { SAIDAS } from './lib.mjs'

const rotulo = process.argv[2] ?? 'D'
const TABELAS = ['instituicao', 'conta', 'cartao', 'categoria', 'fatura', 'compra_parcelada', 'lancamento', 'evento_de_uso']
const log = []
let falhas = 0
const registrar = (linha) => {
  log.push(linha)
  console.log(linha)
}
const conferir = (descricao, obtido, esperado) => {
  const ok = obtido === esperado
  if (!ok) falhas++
  registrar(`${ok ? 'OK     ' : 'FALHOU '} ${descricao}: obtido=${obtido} esperado=${esperado}`)
}
const comUsuario = (uid, sql) =>
  psql('app_runtime', `BEGIN;\n${uid ? `SELECT set_config('app.usuario_id', '${uid}', true) \\g /dev/null\n` : ''}${sql}\nCOMMIT;\n`).trim()

registrar(`== Isolamento no estado "${rotulo}" ==`)
registrar(psql('postgres', "SELECT tablename || ': ' || qual FROM pg_policies WHERE policyname = 'dados_do_usuario' AND tablename = 'lancamento';").trim())

// Dois usuários novos, sem dados.
const sufixo = Date.now()
const [A, B] = ['a', 'b'].map((x) =>
  psql('app_migrador', `INSERT INTO usuario (nome, email) VALUES ('Isolamento ${x}', 'iso-${x}-${sufixo}@exemplo.test') RETURNING id;`).trim(),
)
registrar(`USUARIO_A=${A} USUARIO_B=${B}`)

// Uma linha de A em cada tabela com RLS, com o usuario_id vindo do DEFAULT app_usuario_atual().
const ids = Object.fromEntries(
  comUsuario(
    A,
    `WITH i AS (INSERT INTO instituicao (nome) VALUES ('Banco Ficticio') RETURNING id),
          c AS (INSERT INTO conta (nome, tipo, instituicao_id) SELECT 'Corrente', 'corrente', id FROM i RETURNING id),
          k AS (INSERT INTO cartao (nome, dia_fechamento, dia_vencimento) VALUES ('Cartao', 25, 5) RETURNING id),
          g AS (INSERT INTO categoria (nome) VALUES ('Mercado') RETURNING id),
          f AS (INSERT INTO fatura (cartao_id, mes_referencia, data_fechamento, data_vencimento)
                SELECT id, '2026-10', '2026-09-25', '2026-10-05' FROM k RETURNING id),
          p AS (INSERT INTO compra_parcelada (cartao_id, valor_total_centavos, parcelas, data_compra)
                SELECT id, 60000, 3, '2026-09-20' FROM k RETURNING id),
          l AS (INSERT INTO lancamento (tipo, valor_centavos, data_lancamento, mes_competencia, conta_id, categoria_id, forma_pagamento, origem)
                SELECT 'gasto', 3250, '2026-09-27', '2026-09', c.id, g.id, 'pix', 'formulario' FROM c, g RETURNING id),
          e AS (INSERT INTO evento_de_uso (tipo) VALUES ('lancamento') RETURNING id)
     SELECT 'instituicao', id FROM i UNION ALL SELECT 'conta', id FROM c UNION ALL SELECT 'cartao', id FROM k
     UNION ALL SELECT 'categoria', id FROM g UNION ALL SELECT 'fatura', id FROM f UNION ALL SELECT 'compra_parcelada', id FROM p
     UNION ALL SELECT 'lancamento', id FROM l UNION ALL SELECT 'evento_de_uso', id FROM e;`,
  )
    .split('\n')
    .map((l) => l.split('|')),
)
registrar(`semeado para A: ${Object.keys(ids).join(', ')}`)

const contar = (uid, t) => Number(comUsuario(uid, `SELECT count(*) FROM ${t};`))

registrar('-- Caso 1: B não vê nada de A, em nenhuma tabela com RLS')
for (const t of TABELAS) {
  conferir(`${t}: A conta`, contar(A, t), 1)
  conferir(`${t}: B conta`, contar(B, t), 0)
}

registrar('-- Caso 2: B não muda nem apaga as linhas de A, nem move uma linha para si trocando o usuario_id')
for (const t of TABELAS) {
  const n = Number(comUsuario(B, `WITH x AS (UPDATE ${t} SET usuario_id = '${B}' WHERE id = '${ids[t]}' RETURNING 1) SELECT count(*) FROM x;`))
  conferir(`${t}: UPDATE de B na linha de A (linhas afetadas)`, n, 0)
}
for (const t of [...TABELAS].reverse()) {
  const n = Number(comUsuario(B, `WITH x AS (DELETE FROM ${t} RETURNING 1) SELECT count(*) FROM x;`))
  conferir(`${t}: DELETE de B (linhas afetadas)`, n, 0)
  conferir(`${t}: A ainda conta`, contar(A, t), 1)
}

registrar('-- Caso 3 (bônus): B não grava uma linha com o usuario_id de A')
for (const [t, sql] of [
  ['instituicao', `INSERT INTO instituicao (usuario_id, nome) VALUES ('${A}', 'Intrusa')`],
  ['lancamento', `INSERT INTO lancamento (usuario_id, tipo, valor_centavos, data_lancamento, mes_competencia, conta_id, origem) VALUES ('${A}', 'entrada', 100, '2026-09-27', '2026-09', '${ids.conta}', 'formulario')`],
]) {
  let erro = ''
  try {
    comUsuario(B, `${sql};`)
  } catch (e) {
    erro = String(e.message)
  }
  conferir(`${t}: INSERT de B com usuario_id de A é recusado pelo RLS`, /row-level security/.test(erro), true)
}

registrar('-- Falha fechada: sem marca de usuário, a leitura dá erro')
{
  let erro = ''
  try {
    comUsuario(null, 'SELECT count(*) FROM lancamento;')
  } catch (e) {
    erro = String(e.message)
  }
  conferir('lancamento sem set_config: erro app_usuario_ausente', /app_usuario_ausente/.test(erro), true)
}

registrar('-- Volume: com RLS, cada perfil vê exatamente as suas linhas (conferido como postgres, sem RLS)')
for (const [perfil, uid] of Object.entries(idsDosPerfis())) {
  const comRls = contar(uid, 'lancamento')
  const real = Number(psql('postgres', `SELECT count(*) FROM lancamento WHERE usuario_id = '${uid}';`).trim())
  conferir(`lancamento ${perfil}: contagem com RLS = contagem filtrada`, comRls, real)
  conferir(
    `lancamento ${perfil}: nenhuma linha de outro usuário visível`,
    Number(comUsuario(uid, `SELECT count(*) FROM lancamento WHERE usuario_id <> '${uid}';`)),
    0,
  )
}

registrar(`== Resultado: ${falhas === 0 ? 'todas as conferências passaram' : `${falhas} conferência(s) falharam`} ==`)
mkdirSync(SAIDAS, { recursive: true })
writeFileSync(join(SAIDAS, `07_isolamento_${rotulo}.txt`), log.join('\n') + '\n')
process.exitCode = falhas === 0 ? 0 : 1
