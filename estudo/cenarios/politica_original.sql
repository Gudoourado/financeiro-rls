-- Volta a política dados_do_usuario ao texto da migração 02_multiusuario.sql (cenários A e C).
-- Roda como app_migrador, no banco estudo_rls.
\set ON_ERROR_STOP 1
BEGIN;
ALTER POLICY dados_do_usuario ON instituicao      USING (usuario_id = public.app_usuario_atual()) WITH CHECK (usuario_id = public.app_usuario_atual());
ALTER POLICY dados_do_usuario ON conta            USING (usuario_id = public.app_usuario_atual()) WITH CHECK (usuario_id = public.app_usuario_atual());
ALTER POLICY dados_do_usuario ON cartao           USING (usuario_id = public.app_usuario_atual()) WITH CHECK (usuario_id = public.app_usuario_atual());
ALTER POLICY dados_do_usuario ON categoria        USING (usuario_id = public.app_usuario_atual()) WITH CHECK (usuario_id = public.app_usuario_atual());
ALTER POLICY dados_do_usuario ON fatura           USING (usuario_id = public.app_usuario_atual()) WITH CHECK (usuario_id = public.app_usuario_atual());
ALTER POLICY dados_do_usuario ON compra_parcelada USING (usuario_id = public.app_usuario_atual()) WITH CHECK (usuario_id = public.app_usuario_atual());
ALTER POLICY dados_do_usuario ON lancamento       USING (usuario_id = public.app_usuario_atual()) WITH CHECK (usuario_id = public.app_usuario_atual());
ALTER POLICY dados_do_usuario ON evento_de_uso    USING (usuario_id = public.app_usuario_atual()) WITH CHECK (usuario_id = public.app_usuario_atual());
COMMIT;
SELECT tablename, qual, with_check FROM pg_policies WHERE policyname = 'dados_do_usuario' ORDER BY 1;
