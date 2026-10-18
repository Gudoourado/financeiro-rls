-- Cenário B (e D): a política dados_do_usuario reescrita para chamar a função uma vez por consulta (InitPlan).
-- Roda como app_migrador (dono das tabelas), no banco estudo_rls. Só muda as expressões da política.
\set ON_ERROR_STOP 1
BEGIN;
ALTER POLICY dados_do_usuario ON instituicao      USING (usuario_id = (SELECT public.app_usuario_atual())) WITH CHECK (usuario_id = (SELECT public.app_usuario_atual()));
ALTER POLICY dados_do_usuario ON conta            USING (usuario_id = (SELECT public.app_usuario_atual())) WITH CHECK (usuario_id = (SELECT public.app_usuario_atual()));
ALTER POLICY dados_do_usuario ON cartao           USING (usuario_id = (SELECT public.app_usuario_atual())) WITH CHECK (usuario_id = (SELECT public.app_usuario_atual()));
ALTER POLICY dados_do_usuario ON categoria        USING (usuario_id = (SELECT public.app_usuario_atual())) WITH CHECK (usuario_id = (SELECT public.app_usuario_atual()));
ALTER POLICY dados_do_usuario ON fatura           USING (usuario_id = (SELECT public.app_usuario_atual())) WITH CHECK (usuario_id = (SELECT public.app_usuario_atual()));
ALTER POLICY dados_do_usuario ON compra_parcelada USING (usuario_id = (SELECT public.app_usuario_atual())) WITH CHECK (usuario_id = (SELECT public.app_usuario_atual()));
ALTER POLICY dados_do_usuario ON lancamento       USING (usuario_id = (SELECT public.app_usuario_atual())) WITH CHECK (usuario_id = (SELECT public.app_usuario_atual()));
ALTER POLICY dados_do_usuario ON evento_de_uso    USING (usuario_id = (SELECT public.app_usuario_atual())) WITH CHECK (usuario_id = (SELECT public.app_usuario_atual()));
COMMIT;
SELECT tablename, qual, with_check FROM pg_policies WHERE policyname = 'dados_do_usuario' ORDER BY 1;
