// Conta quantas vezes app_usuario_atual() roda numa execução de cada consulta (planejamento + execução), pelo
// pg_stat_user_functions. Exige track_functions = 'pl' no banco do estudo (ALTER DATABASE estudo_rls, feito pelo
// 01_preparar.sh; só vale para esse banco). Uso: node 05_contar_chamadas.mjs <cenario>
// Cada consulta roda numa sessão própria do app_runtime (sem EXPLAIN); ao fim da sessão as estatísticas são
// gravadas, e a sessão do postgres lê o contador antes e depois.
import { appendFileSync } from 'node:fs'
import { join } from 'node:path'
import { idsDosPerfis, psql, textoDaConsulta } from './04_medir.mjs'
import { SAIDAS } from './lib.mjs'

const cenario = process.argv[2]
const esperar = (ms) => new Promise((r) => setTimeout(r, ms))
const contador = () =>
  Number(
    psql(
      'postgres',
      "SELECT pg_stat_clear_snapshot(); SELECT coalesce((SELECT calls FROM pg_stat_user_functions WHERE funcname = 'app_usuario_atual'), 0);",
    )
      .trim()
      .split('\n')
      .pop(),
  )

const ids = idsDosPerfis()
for (const consulta of ['q1', 'q2', 'q3']) {
  for (const [perfil, uid] of Object.entries(ids)) {
    const antes = contador()
    psql(
      'app_runtime',
      `BEGIN;\nSELECT set_config('app.usuario_id', '${uid}', true) \\g /dev/null\n${textoDaConsulta(consulta, uid)} \\g /dev/null\nCOMMIT;\n`,
    )
    await esperar(1500)
    const depois = contador()
    const linha = `${cenario} ${consulta} ${perfil} chamadas_de_app_usuario_atual=${depois - antes}`
    console.log(linha)
    appendFileSync(join(SAIDAS, '05_chamadas.txt'), linha + '\n')
  }
}
