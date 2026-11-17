alter table numix_private.skill_levels drop constraint if exists skill_levels_skill_check;
alter table numix_private.skill_levels add constraint skill_levels_skill_check
  check(skill in ('luck','trade','speed','collector','greater_luck','no_fee'));
