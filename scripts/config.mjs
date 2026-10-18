// Configuração de conexão, lida do .env (veja o .env.example). Usada pelos scripts e pelos testes.
import { existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

export const RAIZ = join(dirname(fileURLToPath(import.meta.url)), '..')

const arquivoEnv = join(RAIZ, '.env')
if (existsSync(arquivoEnv)) process.loadEnvFile(arquivoEnv)

/** O banco dos testes. O nome termina em _teste: os testes apagam os dados dele a cada execução. */
export const BANCO_DE_TESTE = 'rls_teste'

function exigir(nome) {
  const valor = process.env[nome]
  if (!valor) throw new Error(`Falta ${nome} no ambiente. Copie o .env.example para .env e preencha.`)
  return valor
}

export const PORTA = Number(process.env.POSTGRES_PORTA ?? 55433)

const SENHAS = {
  postgres: () => exigir('POSTGRES_PASSWORD'),
  app_migrador: () => exigir('APP_MIGRADOR_SENHA'),
  app_runtime: () => exigir('APP_RUNTIME_SENHA'),
}

/** Parâmetros de conexão do node-pg para um papel e um banco, no Postgres local do compose.yaml. */
export function conexao(papel, banco) {
  const senha = SENHAS[papel]
  if (!senha) throw new Error(`Papel desconhecido: ${papel}`)
  return { host: '127.0.0.1', port: PORTA, user: papel, password: senha(), database: banco }
}
