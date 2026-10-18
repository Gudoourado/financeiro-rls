// Resume estudo/saidas/resultados.jsonl em tabelas de texto (Markdown) em estudo/saidas/08_resumo.txt.
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { SAIDAS } from './lib.mjs'

const linhas = readFileSync(join(SAIDAS, 'resultados.jsonl'), 'utf8').trim().split('\n').map(JSON.parse)
const ORDEM = ['A', 'B', 'C', 'D', 'REF_A', 'REF_C']
const f = (x) => (x === undefined ? '' : x < 10 ? x.toFixed(2) : x.toFixed(1))

function tipoDePlano(nos) {
  // só os nós de leitura de lancamento e as operações de topo, sem repetição
  return nos
    .filter((n) => /lancamento|fatura|Sort|Limit|Nested|BitmapAnd|InitPlan|Result/.test(n))
    .map((n) => n.replace(' on lancamento', '').replace(' on fatura', '(fatura)'))
    .join(' > ')
}

let saida = ''
for (const consulta of ['q1', 'q2', 'q3']) {
  saida += `\n### ${consulta}\n\n| rodada | cenário | perfil | mediana (ms) | p95 (ms) | mín (ms) | máx (ms) | pgbench média (ms) | linhas devolvidas | linhas lidas | buffers hit+read | plano |\n|---|---|---|---|---|---|---|---|---|---|---|---|\n`
  const doGrupo = linhas
    .filter((l) => l.consulta === consulta)
    .sort((a, b) => a.rodada.localeCompare(b.rodada) || ORDEM.indexOf(a.cenario) - ORDEM.indexOf(b.cenario) || a.perfil.localeCompare(b.perfil))
  for (const l of doGrupo) {
    const lidas = Object.entries(l.linhasLidas).map(([t, n]) => `${t}=${n}`).join(', ')
    saida += `| ${l.rodada} | ${l.cenario} | ${l.perfil} | ${f(l.mediana_ms)} | ${f(l.p95_ms)} | ${f(l.min_ms)} | ${f(l.max_ms)} | ${f(l.pgbench_media_ms)} | ${l.linhasDevolvidas} | ${lidas} | ${l.buffersHit}+${l.buffersRead} | ${tipoDePlano(l.nos)} |\n`
  }
}
writeFileSync(join(SAIDAS, '08_resumo.txt'), saida)
console.log(saida)
