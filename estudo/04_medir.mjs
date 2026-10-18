// Medição do estudo de RLS. Uso: node 04_medir.mjs <cenario> [explorar]
//   cenario: A | B | C | D (como app_runtime, com o usuário marcado por set_config dentro da transação)
//            REF_A | REF_C (como postgres, superusuário: sem RLS, com WHERE usuario_id explícito)
// Para cada consulta (q1, q2, q3) e cada perfil de usuário (pesado, mediano, leve): 1 aquecimento + N medições de
// EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON), cada uma na sua transação, como a unidade de trabalho do app faz.
// Guarda a saída crua do psql em estudo/saidas/brutos/ e o plano em texto (uma execução extra, fora da conta) em
// estudo/saidas/planos/. O resumo vai para estudo/saidas/resultados.jsonl (uma linha por série).
// Variáveis: RODADA (padrão 1), MEDICOES (padrão 30), ESTUDO_BANCO (padrão estudo_rls).
import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { AQUI, BANCO, SAIDAS, noConteiner, psql } from './lib.mjs'

export { psql }
const MEDICOES = Number(process.env.MEDICOES ?? 30) // além de 1 aquecimento
const RODADA = process.env.RODADA ?? '1'
const PGBENCH_TRANSACOES = Number(process.env.MEDICOES ?? 30)
const MES = '2026-09'
const MES_SEGUINTE = '2026-10'
const PERFIS = { pesado: 'pessoa1@exemplo.test', mediano: 'pessoa100@exemplo.test', leve: 'pessoa200@exemplo.test' }
const CONSULTAS = ['q1', 'q2', 'q3']

export function idsDosPerfis() {
  const ids = {}
  for (const [perfil, email] of Object.entries(PERFIS)) {
    ids[perfil] = psql('postgres', `SELECT id FROM usuario WHERE email = '${email}';`).trim()
  }
  return ids
}

export function textoDaConsulta(nome, uid) {
  return readFileSync(join(AQUI, 'consultas', `${nome}.sql`), 'utf8')
    .split('\n')
    .filter((l) => !l.trim().startsWith('--'))
    .join('\n')
    .trim()
    .replaceAll(":'uid'", `'${uid}'`)
    .replaceAll(":'mes_seguinte'", `'${MES_SEGUINTE}'`)
    .replaceAll(":'mes'", `'${MES}'`)
}

function percentil(ordenados, p) {
  // nearest-rank
  const k = Math.max(1, Math.ceil(p * ordenados.length))
  return ordenados[k - 1]
}
function mediana(ordenados) {
  const n = ordenados.length
  return n % 2 ? ordenados[(n - 1) / 2] : (ordenados[n / 2 - 1] + ordenados[n / 2]) / 2
}

function percorrer(no, f) {
  f(no)
  for (const filho of no.Plans ?? []) percorrer(filho, f)
}

function resumirPlano(plano) {
  const nos = []
  const lidas = {}
  let chamadasNoFiltro = false
  percorrer(plano.Plan, (no) => {
    const rotulo = [no['Node Type'], no['Index Name'] ? `using ${no['Index Name']}` : null, no['Relation Name'] ? `on ${no['Relation Name']}` : null]
      .filter(Boolean)
      .join(' ')
    nos.push(rotulo)
    if (no['Relation Name'] && /Scan$/.test(no['Node Type']) && no['Node Type'] !== 'Bitmap Index Scan') {
      const loops = no['Actual Loops'] ?? 1
      const n = ((no['Actual Rows'] ?? 0) + (no['Rows Removed by Filter'] ?? 0) + (no['Rows Removed by Index Recheck'] ?? 0)) * loops
      lidas[no['Relation Name']] = (lidas[no['Relation Name']] ?? 0) + n
    }
    if ((no.Filter ?? '').includes('app_usuario_atual')) chamadasNoFiltro = true
  })
  return {
    nos,
    linhasDevolvidas: plano.Plan['Actual Rows'],
    linhasLidas: lidas,
    buffersHit: plano.Plan['Shared Hit Blocks'] ?? 0,
    buffersRead: plano.Plan['Shared Read Blocks'] ?? 0,
    funcaoNoFiltro: chamadasNoFiltro,
    temInitPlan: JSON.stringify(plano).includes('"InitPlan"') || JSON.stringify(plano).includes('InitPlan'),
  }
}

function medirSerie(cenario, consulta, perfil, uid) {
  const ehRef = cenario.startsWith('REF')
  const usuario = ehRef ? 'postgres' : 'app_runtime'
  const sql = textoDaConsulta(ehRef ? `${consulta}_ref` : consulta, uid)
  const marca = `SELECT set_config('app.usuario_id', '${uid}', true) \\g /dev/null\n`
  let script = ''
  for (let i = 0; i <= MEDICOES; i++) {
    script += `\\echo @@RUN ${i}\nBEGIN;\n${ehRef ? '' : marca}EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)\n${sql};\nCOMMIT;\n`
  }
  script += `\\echo @@TEXTO\nBEGIN;\n${ehRef ? '' : marca}EXPLAIN (ANALYZE, BUFFERS, VERBOSE)\n${sql};\nCOMMIT;\n`
  const saida = psql(usuario, script)
  const nome = `r${RODADA}_${cenario}_${consulta}_${perfil}`
  writeFileSync(join(SAIDAS, 'brutos', `${nome}.txt`), `-- papel: ${usuario}\n-- script enviado ao psql:\n${script}\n-- saída crua:\n${saida}`)
  const [parteJson, parteTexto] = saida.split('@@TEXTO')
  writeFileSync(join(SAIDAS, 'planos', `${nome}.txt`), `-- ${nome} (papel ${usuario}); execução extra, fora da conta\n${sql};\n\n${parteTexto.trim()}\n`)
  const execs = []
  const planejamentos = []
  let resumo = null
  for (const bloco of parteJson.split(/@@RUN \d+\n/).filter((b) => b.trim())) {
    const plano = JSON.parse(bloco)[0]
    execs.push(plano['Execution Time'])
    planejamentos.push(plano['Planning Time'])
    resumo = resumirPlano(plano) // o da última medição
  }
  if (execs.length !== MEDICOES + 1) throw new Error(`${nome}: esperava ${MEDICOES + 1} planos, veio ${execs.length}`)
  const medidas = execs.slice(1)
  const ord = [...medidas].sort((a, b) => a - b)
  const ordP = [...planejamentos.slice(1)].sort((a, b) => a - b)
  return {
    cenario,
    consulta,
    perfil,
    papel: usuario,
    n: medidas.length,
    aquecimento_ms: execs[0],
    execucao_ms: medidas,
    mediana_ms: mediana(ord),
    p95_ms: percentil(ord, 0.95),
    min_ms: ord[0],
    max_ms: ord[ord.length - 1],
    planejamento_mediana_ms: mediana(ordP),
    ...resumo,
  }
}

// Conferência sem EXPLAIN: o pgbench roda BEGIN; set_config; consulta; COMMIT (como a unidade de trabalho) e devolve
// a latência média, por comando, medida no cliente (dentro do contêiner, por socket). Só para o usuário pesado.
function pgbenchSerie(cenario, consulta, uid) {
  const ehRef = cenario.startsWith('REF')
  const usuario = ehRef ? 'postgres' : 'app_runtime'
  const sql = textoDaConsulta(ehRef ? `${consulta}_ref` : consulta, uid).replace(/\s+/g, ' ')
  const script = `BEGIN;\n${ehRef ? '' : `SELECT set_config('app.usuario_id', '${uid}', true);\n`}${sql};\nCOMMIT;\n`
  const r = noConteiner(['pgbench', '-n', '-r', '-t', String(PGBENCH_TRANSACOES), '-U', usuario, '-f', '-', BANCO], script)
  if (r.status !== 0) throw new Error(`pgbench falhou: ${r.stderr}`)
  const saida = r.stdout + r.stderr
  writeFileSync(join(SAIDAS, 'brutos', `r${RODADA}_${cenario}_${consulta}_pesado_pgbench.txt`), `-- script:\n${script}\n-- saída crua:\n${saida}`)
  const linha = saida.split('\n').find((l) => /^\s+[\d.]+\s+\d+\s+SELECT (id|f\.cartao_id|forma_pagamento)/.test(l))
  if (!linha) throw new Error(`pgbench: não achei a linha da consulta em\n${saida}`)
  return Number(linha.trim().split(/\s+/)[0])
}

function principal() {
  const cenario = process.argv[2]
  if (!/^(A|B|C|D|REF_A|REF_C)$/.test(cenario ?? '')) {
    console.error('uso: node 04_medir.mjs <A|B|C|D|REF_A|REF_C>')
    process.exit(1)
  }
  mkdirSync(join(SAIDAS, 'brutos'), { recursive: true })
  mkdirSync(join(SAIDAS, 'planos'), { recursive: true })
  const ids = idsDosPerfis()
  for (const consulta of CONSULTAS) {
    for (const [perfil, uid] of Object.entries(ids)) {
      const r = { rodada: RODADA, ...medirSerie(cenario, consulta, perfil, uid) }
      if (perfil === 'pesado') r.pgbench_media_ms = pgbenchSerie(cenario, consulta, uid)
      appendFileSync(join(SAIDAS, 'resultados.jsonl'), JSON.stringify({ medido_em: new Date().toISOString(), ...r }) + '\n')
      console.log(
        `${cenario} ${consulta} ${perfil.padEnd(7)} mediana=${r.mediana_ms.toFixed(3)}ms p95=${r.p95_ms.toFixed(3)}ms ` +
          `devolvidas=${r.linhasDevolvidas} lidas=${JSON.stringify(r.linhasLidas)} buffers=${r.buffersHit}+${r.buffersRead} ` +
          `| ${r.nos.join(' > ')}`,
      )
    }
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) principal()
