-- The migration helpers execute their text arguments as SQL. Only migrations call
-- them (as the owner), so no runtime role may execute them.
REVOKE EXECUTE ON FUNCTION public.sp_add_constraint(regclass, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.sp_set_fk(regclass, text, regclass, text, text) FROM PUBLIC;
