-- Make mungaidickson80@gmail.com the administrator.
-- Run this AFTER you create that login in Supabase > Authentication > Users > Add user
-- (use exactly this email, tick "Auto Confirm User" if you see it, and choose a password).
insert into dairy_profiles(id,email,full_name,status,is_admin)
select id,email,'Administrator','approved',true from auth.users where lower(email)=lower('mungaidickson80@gmail.com')
on conflict (id) do update set status='approved',is_admin=true;
-- Check: this should show one row with is_admin = true
select email,status,is_admin from dairy_profiles where is_admin;
