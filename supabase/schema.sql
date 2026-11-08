-- =====================================================================
-- Appli de swipe de recettes : schéma Supabase (Postgres)
-- Ordre d'exécution : schema.sql, puis seed.sql (catalogue généré)
-- =====================================================================
-- Sur Supabase, les extensions vivent dans le schéma « extensions »
create extension if not exists pg_trgm with schema extensions;
create extension if not exists unaccent with schema extensions;

-- Normalisation de texte (minuscules, sans accents) pour la recherche et les doublons
create or replace function norm(t text) returns text
language sql immutable as $$
  select regexp_replace(lower(extensions.unaccent('extensions.unaccent', coalesce(t, ''))), '[^a-z0-9]+', ' ', 'g')
$$;

-- Normalisation d'URL pour détecter les imports en double
create or replace function norm_url(u text) returns text
language sql immutable as $$
  select regexp_replace(
           regexp_replace(lower(split_part(split_part(coalesce(u, ''), '#', 1), '?', 1)),
                          '^https?://(www\.)?', ''),
           '/+$', '')
$$;

-- ---------------------------------------------------------------------
-- Référentiel (lecture seule pour les utilisateurs)
-- ---------------------------------------------------------------------
create table ingredients (
  id               text primary key,
  nom              text not null,
  rayon            text not null,
  rayon_nom        text not null,
  rayon_ordre      int  not null,
  unite_base       text not null check (unite_base in ('g', 'ml', 'u')),
  densite          numeric,
  poids_unitaire_g numeric,
  achat_quantite   numeric not null,
  achat_libelle    text not null,
  prix_achat_eur   numeric not null,
  kcal_100g        numeric not null,
  proteines_100g   numeric not null,
  glucides_100g    numeric not null,
  lipides_100g     numeric not null,
  allergenes       text[] not null default '{}',
  marqueurs        text[] not null default '{}',
  saison_mois      int[],               -- null = non concerné, '{}' = jamais de saison
  nom_norm         text generated always as (norm(nom)) stored
);
create index on ingredients using gin (nom_norm extensions.gin_trgm_ops);

create table recipes (
  id                    text primary key,
  titre                 text not null,
  categorie             text not null check (categorie in ('entree','salade','soupe','plat','accompagnement','dessert','petit-dej')),
  difficulte            text not null check (difficulte in ('facile','moyen','difficile')),
  temps_preparation_min int not null,
  temps_cuisson_min     int not null,
  temps_total_min       int not null,
  portions              int not null check (portions > 0),
  cuisine               text,
  tags                  text[] not null default '{}',
  etapes                text[] not null default '{}',
  kcal_portion          int,
  proteines_portion_g   numeric,
  glucides_portion_g    numeric,
  lipides_portion_g     numeric,
  cout_total_eur        numeric,
  cout_portion_eur      numeric,
  allergenes            text[] not null default '{}',
  regimes               text[] not null default '{}',
  contient_alcool       boolean not null default false,
  mois_saison           int[] not null default '{}',
  toute_annee           boolean not null default false,
  image_url             text,
  -- origine : catalogue (base commune), import (depuis un lien), perso (saisie manuelle)
  origine               text not null default 'catalogue' check (origine in ('catalogue','import','perso')),
  source_url            text,
  source_url_norm       text generated always as (nullif(norm_url(source_url), '')) stored,
  cree_par              uuid references auth.users on delete set null,
  groupe_id             uuid,           -- recette importée partagée avec un groupe (null = privée ou catalogue)
  titre_norm            text generated always as (norm(titre)) stored,
  cree_le               timestamptz not null default now()
);
create unique index recipes_source_url_uniq on recipes (source_url_norm) where source_url_norm is not null;
create index on recipes using gin (titre_norm extensions.gin_trgm_ops);
create index on recipes using gin (regimes);
create index on recipes using gin (allergenes);
create index on recipes using gin (mois_saison);

create table recipe_ingredients (
  recipe_id     text not null references recipes on delete cascade,
  position      int  not null,
  ingredient_id text not null references ingredients,
  quantite      numeric,                 -- null = « selon goût »
  unite         text,
  quantite_base numeric,                 -- convertie dans l'unité de base de l'ingrédient
  grammes       numeric,
  note          text,
  primary key (recipe_id, position)
);
create index on recipe_ingredients (ingredient_id);

-- ---------------------------------------------------------------------
-- Utilisateurs, groupes
-- ---------------------------------------------------------------------
create table profiles (
  user_id             uuid primary key references auth.users on delete cascade,
  pseudo              text not null,
  regimes             text[] not null default '{}',  -- ex. {vegetarien} ou {compatible_halal}
  allergenes_exclus   text[] not null default '{}',  -- codes UE : GLU, LAI, ARA...
  ingredients_exclus  text[] not null default '{}',  -- ids d'ingrédients non aimés
  cree_le             timestamptz not null default now()
);

create table groups (
  id               uuid primary key default gen_random_uuid(),
  nom              text not null,
  -- règle de match réglable par groupe
  regle_match      text not null default 'unanimite' check (regle_match in ('unanimite','majorite','seuil')),
  seuil_pct        int  not null default 50 check (seuil_pct between 1 and 100),
  saison_stricte   boolean not null default false,  -- ne proposer que des recettes de saison
  nb_personnes     int  not null default 2,         -- convives par défaut pour les menus
  code_invitation  text not null unique default substr(md5(random()::text), 1, 8),
  cree_par         uuid not null references auth.users,
  cree_le          timestamptz not null default now()
);
alter table recipes add constraint recipes_groupe_fk foreign key (groupe_id) references groups on delete set null;

create table group_members (
  group_id  uuid not null references groups on delete cascade,
  user_id   uuid not null references auth.users on delete cascade,
  role      text not null default 'membre' check (role in ('admin','membre')),
  rejoint_le timestamptz not null default now(),
  primary key (group_id, user_id)
);
create index on group_members (user_id);

-- ---------------------------------------------------------------------
-- Goûts : un avis par utilisateur et par recette (swipe ou like depuis la recherche)
-- ---------------------------------------------------------------------
create table swipes (
  user_id    uuid not null references auth.users on delete cascade,
  recipe_id  text not null references recipes on delete cascade,
  avis       text not null check (avis in ('like','dislike','super_like')),
  source     text not null default 'swipe' check (source in ('swipe','recherche','menu')),
  maj_le     timestamptz not null default now(),
  primary key (user_id, recipe_id)
);
create index on swipes (recipe_id);

-- ---------------------------------------------------------------------
-- Menus de la semaine et liste de courses
-- ---------------------------------------------------------------------
create table menus (
  id            uuid primary key default gen_random_uuid(),
  group_id      uuid not null references groups on delete cascade,
  semaine_debut date not null,
  cree_par      uuid references auth.users,
  cree_le       timestamptz not null default now(),
  unique (group_id, semaine_debut)
);

create table menu_items (
  id         uuid primary key default gen_random_uuid(),
  menu_id    uuid not null references menus on delete cascade,
  recipe_id  text not null references recipes,
  jour       date,
  repas      text check (repas in ('petit-dej','midi','soir')),
  portions   int not null check (portions > 0)
);
create index on menu_items (menu_id);

-- Ce que le groupe a déjà dans ses placards (« j'en ai déjà »)
create table group_pantry (
  group_id      uuid not null references groups on delete cascade,
  ingredient_id text not null references ingredients,
  quantite_base numeric,          -- null = « en stock », quantité non précisée
  maj_le        timestamptz not null default now(),
  primary key (group_id, ingredient_id)
);

create table shopping_list_items (
  id                uuid primary key default gen_random_uuid(),
  menu_id           uuid not null references menus on delete cascade,
  ingredient_id     text references ingredients,
  libelle_libre     text,                 -- article ajouté à la main
  quantite_besoin   numeric,              -- unité de base, somme des recettes
  quantite_deja     numeric not null default 0,
  nb_achats         int,                  -- nombre d'unités d'achat, arrondi au-dessus
  achat_libelle     text,
  cout_estime_eur   numeric,
  rayon_nom         text,
  rayon_ordre       int,
  selon_gout        boolean not null default false,  -- sel, poivre... à vérifier dans le placard
  deja_en_stock     boolean not null default false,
  coche             boolean not null default false,
  check (ingredient_id is not null or libelle_libre is not null)
);
create index on shopping_list_items (menu_id);

-- Suivi des imports depuis un lien
create table recipe_imports (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users on delete cascade,
  url         text not null,
  statut      text not null default 'en_cours' check (statut in ('en_cours','ok','doublon','a_verifier','erreur')),
  recipe_id   text references recipes on delete set null,
  message     text,
  cree_le     timestamptz not null default now()
);

-- =====================================================================
-- Fonctions métier
-- =====================================================================

-- L'utilisateur courant est-il membre du groupe ?
create or replace function is_member(g uuid) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select exists (select 1 from group_members where group_id = g and user_id = auth.uid())
$$;

-- Partage-t-on un groupe avec cet utilisateur ?
create or replace function shares_group(u uuid) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select exists (
    select 1 from group_members a join group_members b using (group_id)
    where a.user_id = auth.uid() and b.user_id = u)
$$;

-- Recette compatible avec les contraintes de TOUS les membres du groupe
create or replace function recipe_compatible_group(r recipes, g uuid) returns boolean
language sql stable as $$
  select not exists (
    select 1 from group_members m join profiles p using (user_id)
    where m.group_id = g
      and ( not (p.regimes <@ r.regimes)
            or p.allergenes_exclus && r.allergenes
            or exists (select 1 from recipe_ingredients ri
                       where ri.recipe_id = r.id and ri.ingredient_id = any (p.ingredients_exclus)))
  )
$$;

-- Matchs d'un groupe, selon sa règle (unanimité, majorité, seuil) et ses filtres
create or replace function group_matches(g uuid, mois int default extract(month from now())::int)
returns table (recipe_id text, titre text, categorie text, nb_likes int, nb_membres int,
               pct_likes int, de_saison boolean, cout_portion_eur numeric, kcal_portion int)
language sql stable security definer set search_path = public, extensions as $$
  with grp as (select * from groups where id = g and is_member(g)),
  n as (select count(*)::int as nb from group_members where group_id = g),
  likes as (
    select s.recipe_id, count(*)::int as nb_likes
    from swipes s join group_members m on m.user_id = s.user_id and m.group_id = g
    where s.avis in ('like','super_like')
    group by s.recipe_id
  )
  select r.id, r.titre, r.categorie, l.nb_likes, n.nb,
         (100 * l.nb_likes / n.nb)::int,
         (mois = any (r.mois_saison)),
         r.cout_portion_eur, r.kcal_portion
  from grp, n, likes l
  join recipes r on r.id = l.recipe_id
  where (r.origine = 'catalogue' or r.groupe_id = g)
    and recipe_compatible_group(r, g)
    and (not grp.saison_stricte or mois = any (r.mois_saison))
    and case grp.regle_match
          when 'unanimite' then l.nb_likes = n.nb
          when 'majorite'  then l.nb_likes * 2 > n.nb
          else 100 * l.nb_likes >= grp.seuil_pct * n.nb
        end
  order by l.nb_likes desc, r.titre
$$;

-- Recettes à proposer au swipe pour un utilisateur dans un groupe :
-- pas encore notées, compatibles avec tout le groupe, de saison si demandé
create or replace function swipe_queue(g uuid, lim int default 30, mois int default extract(month from now())::int)
returns setof recipes
language sql stable security definer set search_path = public, extensions as $$
  select r.* from recipes r, groups grp
  where grp.id = g and is_member(g)
    and (r.origine = 'catalogue' or r.groupe_id = g)
    and not exists (select 1 from swipes s where s.user_id = auth.uid() and s.recipe_id = r.id)
    and recipe_compatible_group(r, g)
    and (not grp.saison_stricte or mois = any (r.mois_saison))
  order by
    -- d'abord ce que les autres membres ont aimé (pour provoquer des matchs)
    (select count(*) from swipes s join group_members m on m.user_id = s.user_id and m.group_id = g
      where s.recipe_id = r.id and s.avis <> 'dislike') desc,
    (mois = any (r.mois_saison)) desc,
    random()
  limit lim
$$;

-- Génère (ou régénère) la liste de courses d'un menu
create or replace function generate_shopping_list(m uuid)
returns setof shopping_list_items
language plpgsql security definer set search_path = public, extensions as $$
declare g uuid;
begin
  select group_id into g from menus where id = m;
  if g is null or not is_member(g) then
    raise exception 'menu introuvable ou accès refusé';
  end if;

  -- on garde les articles ajoutés à la main, on recalcule le reste
  delete from shopping_list_items where menu_id = m and ingredient_id is not null;

  insert into shopping_list_items (menu_id, ingredient_id, quantite_besoin, quantite_deja,
         nb_achats, achat_libelle, cout_estime_eur, rayon_nom, rayon_ordre, selon_gout, deja_en_stock)
  with besoins as (
    select ri.ingredient_id,
           sum(ri.quantite_base * mi.portions / r.portions) as qte,
           bool_and(ri.quantite_base is null) as selon_gout
    from menu_items mi
    join recipes r on r.id = mi.recipe_id
    join recipe_ingredients ri on ri.recipe_id = r.id
    where mi.menu_id = m
    group by ri.ingredient_id
  )
  select m, b.ingredient_id,
         round(coalesce(b.qte, 0), 1),
         coalesce(p.quantite_base, 0),
         a.nb, i.achat_libelle, round(a.nb * i.prix_achat_eur, 2),
         i.rayon_nom, i.rayon_ordre,
         b.selon_gout,
         p.ingredient_id is not null and (p.quantite_base is null or p.quantite_base >= coalesce(b.qte, 0))
  from besoins b
  join ingredients i on i.id = b.ingredient_id
  left join group_pantry p on p.group_id = g and p.ingredient_id = b.ingredient_id
  cross join lateral (
    -- arrondi au-dessus à l'unité d'achat, après déduction du placard
    select case when b.selon_gout or (p.ingredient_id is not null and p.quantite_base is null) then 0
                else greatest(0, ceil(round((coalesce(b.qte, 0) - coalesce(p.quantite_base, 0)) / i.achat_quantite, 3)))::int
           end as nb
  ) a;

  return query select * from shopping_list_items where menu_id = m order by rayon_ordre, achat_libelle;
end $$;

-- Recettes déjà présentes, pour éviter les doublons à l'import (titre proche ou même URL)
create or replace function find_duplicates(p_titre text, p_url text default null)
returns table (recipe_id text, titre text, similarite real, meme_url boolean)
language sql stable set search_path = public, extensions as $$
  select r.id, r.titre,
         greatest(similarity(r.titre_norm, norm(p_titre)), word_similarity(r.titre_norm, norm(p_titre))),
         (p_url is not null and r.source_url_norm = norm_url(p_url))
  from recipes r
  where (p_url is not null and r.source_url_norm = norm_url(p_url))
     or greatest(similarity(r.titre_norm, norm(p_titre)), word_similarity(r.titre_norm, norm(p_titre))) >= 0.7
  order by 4 desc, 3 desc
  limit 5
$$;

-- Recalcule les données dérivées d'une recette (même logique que scripts/build.py).
-- À appeler après l'import ou la modification d'une recette perso.
create or replace function recompute_recipe(rid text) returns recipes
language plpgsql security definer set search_path = public, extensions as $$
declare r recipes;
begin
  -- un utilisateur ne peut recalculer que ses propres recettes (le chargement du catalogue se fait sans auth.uid())
  if auth.uid() is not null and not exists (select 1 from recipes where id = rid and cree_par = auth.uid()) then
    raise exception 'recette introuvable ou accès refusé';
  end if;
  -- 1. conversion des quantités en grammes et en unité de base
  update recipe_ingredients ri set
    grammes = c.g,
    quantite_base = case c.unite_base when 'g' then c.g
                                      when 'ml' then c.g / coalesce(c.densite, 1)
                                      else c.g / nullif(c.poids_unitaire_g, 0) end
  from (
    select x.recipe_id, x.position, i.unite_base, i.densite, i.poids_unitaire_g,
      case
        when x.quantite is null then null
        when x.unite in ('g','kg','pincee') then x.quantite * case x.unite when 'kg' then 1000 when 'pincee' then 0.5 else 1 end
        when x.unite in ('ml','cl','l','cas','cac') then
          x.quantite * case x.unite when 'cl' then 10 when 'l' then 1000 when 'cas' then 15 when 'cac' then 5 else 1 end
          * coalesce(i.densite, case when x.unite in ('cas','cac') and i.unite_base = 'g' then 0.6 else 1 end)
        else x.quantite * i.poids_unitaire_g   -- pièces (u, gousse, tranche, botte...)
      end as g
    from recipe_ingredients x join ingredients i on i.id = x.ingredient_id
    where x.recipe_id = rid
  ) c
  where ri.recipe_id = c.recipe_id and ri.position = c.position;

  -- 2. agrégats
  update recipes rc set
    kcal_portion        = round(a.kcal / rc.portions),
    proteines_portion_g = round(a.prot / rc.portions, 1),
    glucides_portion_g  = round(a.gluc / rc.portions, 1),
    lipides_portion_g   = round(a.lip  / rc.portions, 1),
    cout_total_eur      = round(a.cout, 2),
    cout_portion_eur    = round(a.cout / rc.portions, 2),
    allergenes          = a.allergenes,
    contient_alcool     = 'A' = any (a.marqueurs),
    regimes = array_remove(array[
        case when not a.marqueurs && '{V,P,Po,Cr,L,O,M,G}' then 'vegane' end,
        case when not a.marqueurs && '{V,P,Po,Cr,G}'       then 'vegetarien' end,
        case when not a.marqueurs && '{V,P,G}'             then 'pescetarien' end,
        case when not a.marqueurs && '{P,G}'               then 'sans_porc' end,
        case when not a.marqueurs && '{P,A,G}'             then 'compatible_halal' end,
        case when not 'GLU' = any (a.allergenes)           then 'sans_gluten' end,
        case when not 'LAI' = any (a.allergenes)           then 'sans_lactose' end], null),
    mois_saison = a.mois,
    toute_annee = cardinality(a.mois) = 12,
    temps_total_min = rc.temps_preparation_min + rc.temps_cuisson_min
  from (
    select
      coalesce(sum(i.kcal_100g      * ri.grammes / 100), 0) as kcal,
      coalesce(sum(i.proteines_100g * ri.grammes / 100), 0) as prot,
      coalesce(sum(i.glucides_100g  * ri.grammes / 100), 0) as gluc,
      coalesce(sum(i.lipides_100g   * ri.grammes / 100), 0) as lip,
      coalesce(sum(ri.quantite_base / i.achat_quantite * i.prix_achat_eur), 0) as cout,
      coalesce((select array_agg(distinct x order by x) from recipe_ingredients r2 join ingredients i2 on i2.id = r2.ingredient_id,
                unnest(i2.allergenes) x where r2.recipe_id = rid), '{}') as allergenes,
      coalesce((select array_agg(distinct x) from recipe_ingredients r2 join ingredients i2 on i2.id = r2.ingredient_id,
                unnest(i2.marqueurs) x where r2.recipe_id = rid), '{}') as marqueurs,
      -- saison : intersection des mois des fruits et légumes « principaux » (≥ 20 g par personne)
      (select coalesce(array_agg(m order by m), '{}') from generate_series(1, 12) m
        where not exists (
          select 1 from recipe_ingredients r2 join ingredients i2 on i2.id = r2.ingredient_id
          join recipes rr on rr.id = r2.recipe_id
          where r2.recipe_id = rid and i2.saison_mois is not null
            and r2.grammes / rr.portions >= 20 and not m = any (i2.saison_mois))) as mois
    from recipe_ingredients ri join ingredients i on i.id = ri.ingredient_id
    where ri.recipe_id = rid
  ) a
  where rc.id = rid
  returning rc.* into r;
  return r;
end $$;

-- Correspondance d'un libellé libre (« 2 oignons rouges ») avec le référentiel
create or replace function match_ingredient(libelle text)
returns table (ingredient_id text, nom text, score real)
language sql stable set search_path = public, extensions as $$
  with q as (select t, regexp_replace(t, 's\M', '', 'g') as sing
             from (select trim(norm(libelle)) as t) x)
  select i.id, i.nom,
         case when i.id = replace(q.sing, ' ', '_') or i.nom_norm in (q.t, q.sing) then 1.01::real
              else greatest(similarity(i.nom_norm, q.t), word_similarity(q.t, i.nom_norm)) end as score
  from ingredients i, q
  order by score desc, length(i.nom)
  limit 3
$$;

-- =====================================================================
-- Sécurité (Row Level Security)
-- =====================================================================
alter table ingredients         enable row level security;
alter table recipes             enable row level security;
alter table recipe_ingredients  enable row level security;
alter table profiles            enable row level security;
alter table groups              enable row level security;
alter table group_members       enable row level security;
alter table swipes              enable row level security;
alter table menus               enable row level security;
alter table menu_items          enable row level security;
alter table group_pantry        enable row level security;
alter table shopping_list_items enable row level security;
alter table recipe_imports      enable row level security;

create policy "référentiel lisible" on ingredients for select to authenticated using (true);

create policy "recettes visibles" on recipes for select to authenticated
  using (origine = 'catalogue' or cree_par = auth.uid() or (groupe_id is not null and is_member(groupe_id)));
create policy "recettes perso créables" on recipes for insert to authenticated
  with check (origine in ('import','perso') and cree_par = auth.uid()
              and (groupe_id is null or is_member(groupe_id)));
create policy "recettes perso modifiables" on recipes for update to authenticated
  using (cree_par = auth.uid());

create policy "ingrédients de recette visibles" on recipe_ingredients for select to authenticated
  using (exists (select 1 from recipes r where r.id = recipe_id));
create policy "ingrédients de recette perso" on recipe_ingredients for all to authenticated
  using (exists (select 1 from recipes r where r.id = recipe_id and r.cree_par = auth.uid()))
  with check (exists (select 1 from recipes r where r.id = recipe_id and r.cree_par = auth.uid()));

create policy "mon profil" on profiles for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "profils des co-membres" on profiles for select to authenticated
  using (shares_group(user_id));

create policy "groupes visibles" on groups for select to authenticated using (is_member(id) or cree_par = auth.uid());
create policy "groupes créables" on groups for insert to authenticated with check (cree_par = auth.uid());
create policy "groupes modifiables par admin" on groups for update to authenticated
  using (exists (select 1 from group_members where group_id = id and user_id = auth.uid() and role = 'admin'));

create policy "membres visibles" on group_members for select to authenticated using (is_member(group_id));
create policy "quitter un groupe" on group_members for delete to authenticated using (user_id = auth.uid());

create policy "mes avis" on swipes for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "avis des co-membres" on swipes for select to authenticated using (shares_group(user_id));

create policy "menus du groupe" on menus for all to authenticated
  using (is_member(group_id)) with check (is_member(group_id));
create policy "plats des menus du groupe" on menu_items for all to authenticated
  using (exists (select 1 from menus where id = menu_id and is_member(group_id)))
  with check (exists (select 1 from menus where id = menu_id and is_member(group_id)));
create policy "placard du groupe" on group_pantry for all to authenticated
  using (is_member(group_id)) with check (is_member(group_id));
create policy "courses du groupe" on shopping_list_items for all to authenticated
  using (exists (select 1 from menus where id = menu_id and is_member(group_id)))
  with check (exists (select 1 from menus where id = menu_id and is_member(group_id)));
create policy "mes imports" on recipe_imports for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Rejoindre un groupe avec son code d'invitation
create or replace function join_group(code text) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare g uuid;
begin
  select id into g from groups where code_invitation = code;
  if g is null then raise exception 'code invalide'; end if;
  insert into group_members (group_id, user_id) values (g, auth.uid()) on conflict do nothing;
  return g;
end $$;

-- Le créateur d'un groupe en devient admin
create or replace function on_group_created() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
begin
  insert into group_members (group_id, user_id, role) values (new.id, new.cree_par, 'admin');
  return new;
end $$;
create trigger group_created after insert on groups for each row execute function on_group_created();

-- Liste de courses partagée en temps réel entre les membres
alter publication supabase_realtime add table shopping_list_items;
