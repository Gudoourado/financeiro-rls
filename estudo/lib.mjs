// Acesso ao Postgres do compose.yaml para os scripts do estudo. Tudo passa por "docker compose exec" no serviço
// postgres deste repositório: psql e pgbench rodam dentro do contêiner, pelo socket local, com o papel pedido.
import { spawnSync } from 'node:child_process'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

export const AQUI = dirname(fileURLToPath(import.meta.url))
export const RAIZ = join(AQUI, '..')
export const SAIDAS = join(AQUI, 'saidas')
export const BANCO = process.env.ESTUDO_BANCO ?? 'estudo_rls'
const COMPOSE = ['compose', '-f', join(RAIZ, 'compose.yaml'), 'exec', '-T', 'postgres']

/** Roda um comando dentro do contêiner postgres, com a entrada dada. */
export function noConteiner(argumentos, entrada) {
  return spawnSync('docker', [...COMPOSE, ...argumentos], {
    input: entrada,
    encoding: 'utf8',
    maxBuffer: 512 * 1024 * 1024,
    cwd: RAIZ,
  })
}

export function psql(usuario, sql) {
  const r = noConteiner(['psql', '-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1', '-U', usuario, '-d', BANCO], sql)
  if (r.status !== 0) throw new Error(`psql falhou (${usuario}): ${r.stderr}`)
  return r.stdout
}
