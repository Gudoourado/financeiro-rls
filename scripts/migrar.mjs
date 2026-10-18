// Prepara um banco: cria os papéis (papeis/papeis.sql), define as senhas do .env, cria o banco com dono
// app_migrador e aplica, como app_migrador, cada arquivo de migrations/ que ainda não foi aplicado, um por transação.
// Uso: node scripts/migrar.mjs [--banco <nome>]   (padrão: o banco dos testes)
import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import pg from 'pg'
import { BANCO_DE_TESTE, RAIZ, conexao } from './config.mjs'

const i = process.argv.indexOf('--banco')
const banco = i > 0 ? process.argv[i + 1] : BANCO_DE_TESTE
if (!banco || !/^[a-z_][a-z0-9_]*$/.test(banco)) throw new Error(`Nome de banco inválido: ${banco}`)

async function conectar(config) {
  // O contêiner pode estar subindo: tenta por até 30 s.
  for (let tentativa = 1; ; tentativa++) {
    const cliente = new pg.Client(config)
    try {
      await cliente.connect()
      return cliente
    } catch (erro) {
      await cliente.end().catch(() => undefined)
      if (tentativa >= 30) throw new Error('Postgres fora do ar. Rode "docker compose up -d --wait".', { cause: erro })
      await new Promise((r) => setTimeout(r, 1000))
    }
  }
}

const superusuario = await conectar(conexao('postgres', 'postgres'))
try {
  await superusuario.query(readFileSync(join(RAIZ, 'papeis', 'papeis.sql'), 'utf8'))
  for (const papel of ['app_migrador', 'app_runtime']) {
    const { password } = conexao(papel, banco)
    await superusuario.query(`ALTER ROLE ${papel} PASSWORD ${superusuario.escapeLiteral(password)}`)
  }
  const existe = await superusuario.query('SELECT 1 FROM pg_database WHERE datname = $1', [banco])
  if (existe.rowCount === 0) {
    await superusuario.query(`CREATE DATABASE ${superusuario.escapeIdentifier(banco)} OWNER app_migrador`)
    console.log(`banco ${banco} criado`)
  }
} finally {
  await superusuario.end()
}

const migrador = await conectar(conexao('app_migrador', banco))
try {
  await migrador.query(
    'CREATE TABLE IF NOT EXISTS migracao (nome text PRIMARY KEY, aplicada_em timestamptz NOT NULL DEFAULT now())',
  )
  const aplicadas = new Set((await migrador.query('SELECT nome FROM migracao')).rows.map((r) => r.nome))
  const arquivos = readdirSync(join(RAIZ, 'migrations')).filter((f) => f.endsWith('.sql')).sort()
  for (const arquivo of arquivos) {
    if (aplicadas.has(arquivo)) continue
    await migrador.query('BEGIN')
    try {
      await migrador.query(readFileSync(join(RAIZ, 'migrations', arquivo), 'utf8'))
      await migrador.query('INSERT INTO migracao (nome) VALUES ($1)', [arquivo])
      await migrador.query('COMMIT')
      console.log(`aplicada ${arquivo}`)
    } catch (erro) {
      await migrador.query('ROLLBACK')
      throw new Error(`Falhou ${arquivo}: ${erro.message}`, { cause: erro })
    }
  }
  console.log(`banco ${banco} em dia (${arquivos.length} migrações)`)
} finally {
  await migrador.end()
}
