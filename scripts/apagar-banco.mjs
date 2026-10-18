// Apaga um banco do Postgres local (só o banco; os papéis ficam). Uso: node scripts/apagar-banco.mjs <nome>
import pg from 'pg'
import { conexao } from './config.mjs'

const banco = process.argv[2]
if (!banco || !/^[a-z_][a-z0-9_]*$/.test(banco)) throw new Error('uso: node scripts/apagar-banco.mjs <nome>')
const cliente = new pg.Client(conexao('postgres', 'postgres'))
await cliente.connect()
try {
  await cliente.query(`DROP DATABASE IF EXISTS ${cliente.escapeIdentifier(banco)} WITH (FORCE)`)
  console.log(`banco ${banco} apagado`)
} finally {
  await cliente.end()
}
