// A guarda que o app roda na subida, em versão independente: confere se o papel da conexão está sujeito ao RLS.
// Recusa superusuário, BYPASSRLS, dono de tabela no schema public e membro de outro papel (que poderia herdar um
// desses poderes). Uso: node scripts/verificar-papel.mjs [--banco <nome>]   (conecta como app_runtime)
import pg from 'pg'
import { BANCO_DE_TESTE, conexao } from './config.mjs'

const i = process.argv.indexOf('--banco')
const banco = i > 0 ? process.argv[i + 1] : BANCO_DE_TESTE

const cliente = new pg.Client(conexao('app_runtime', banco))
await cliente.connect()
try {
  const { rows } = await cliente.query(
    `SELECT current_user AS papel,
            r.rolsuper AS superusuario,
            r.rolbypassrls AS ignora_rls,
            EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tableowner = current_user) AS dono_de_tabela,
            EXISTS (SELECT 1 FROM pg_auth_members m WHERE m.member = r.oid) AS herda
       FROM pg_roles r
      WHERE r.rolname = current_user`,
  )
  const estado = rows[0]
  console.log(estado)
  if (!estado || estado.superusuario || estado.ignora_rls || estado.dono_de_tabela || estado.herda) {
    console.error('banco_papel_inseguro: o papel da conexão pode ignorar o RLS. O app não deve subir assim.')
    process.exitCode = 1
  } else {
    console.log('ok: o papel da conexão está sujeito ao RLS.')
  }
} finally {
  await cliente.end()
}
