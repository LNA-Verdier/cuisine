# Base de recettes : catalogue, référentiel et schéma Supabase

Catalogue de 503 recettes du quotidien en français, avec un référentiel de 343 ingrédients, et le schéma Supabase de l'appli (groupes, swipes, matchs, menus, liste de courses, import par lien).

## Contenu

```
src/ingredients.psv          Référentiel d'ingrédients (source, éditable)
src/recettes/*.txt           Les recettes (source, format texte compact)
scripts/build.py             Valide et calcule les données dérivées, génère les exports
data/ingredients.json        Référentiel complet (généré)
data/recettes.json           Recettes complètes avec ingrédients et données calculées (généré)
data/recettes.csv            Vue tableur des recettes (généré)
supabase/schema.sql          Tables, fonctions métier, sécurité (RLS)
supabase/seed.sql            Chargement du catalogue (généré, rechargeable sans perte)
supabase/functions/import-recipe/   Edge Function d'import d'une recette depuis un lien
```

## Le catalogue

| Catégorie | Nombre |
|---|---|
| Plats | 264 |
| Desserts et goûters | 78 |
| Soupes | 42 |
| Salades | 40 |
| Entrées et apéritifs | 34 |
| Accompagnements | 25 |
| Petit-déjeuner, brunch | 20 |

44 cuisines, 402 recettes faciles, 217 recettes prêtes en 30 minutes ou moins. Recettes rédigées pour l'appli, inspirées des classiques de la cuisine familiale (aucun texte copié d'un site).

Pour chaque recette : titre, catégorie, difficulté, temps de préparation et de cuisson, nombre de portions, cuisine, tags, ingrédients avec quantités, étapes. Et calculés automatiquement :

- **kcal, protéines, glucides, lipides par portion**
- **coût total et par portion** (au prorata de ce qui est utilisé)
- **allergènes** (les 14 allergènes réglementaires UE)
- **régimes compatibles** : végane (89), végétarien (307), pescétarien (370), sans porc (459), compatible halal (432), sans gluten (236), sans lactose (198)
- **mois de saison** (291 recettes de saison en janvier, 369 en juillet)

## Règles de calcul

**Régimes.** Chaque ingrédient porte des marqueurs (viande, porc, poisson, fruits de mer, lait, œuf, miel, alcool, gélatine). Une recette est végétarienne si aucun ingrédient ne contient viande, poisson, fruits de mer ou gélatine, etc. « Compatible halal » signifie sans porc, sans alcool et sans gélatine : la viande doit être achetée halal, l'appli ne peut pas le garantir.

**Saison.** Une recette est de saison un mois donné si tous ses fruits et légumes *principaux* le sont. Les aromates en petite quantité (moins de 20 g par personne) ne comptent pas, et les citrons, le gingembre et le piment frais sont traités comme des condiments. Les produits surgelés et en conserve n'ont pas de saison. Les fruits importés (banane, avocat, mangue, ananas) ne sont jamais de saison, donc une recette qui en contient n'apparaît pas quand le filtre saison est actif.

**Compatibilité de groupe.** Une recette n'est proposée à un groupe que si elle respecte les régimes, allergènes et ingrédients exclus de tous ses membres.

**Liste de courses.** Les quantités des recettes du menu sont adaptées au nombre de convives, additionnées par ingrédient, diminuées de ce qui est déjà dans le placard, puis arrondies au-dessus à l'unité d'achat (paquet, botte, boîte…) et triées par rayon. Les ingrédients « selon goût » (sel, poivre) apparaissent à part, à vérifier dans le placard.

## Limites à connaître

- **Nutrition** : valeurs pour 100 g proches de la table Ciqual de l'Anses, saisies à partir de connaissances générales. Ordres de grandeur fiables, mais à vérifier contre Ciqual (https://ciqual.anses.fr) avant d'afficher des chiffres précis. Les poids unitaires sont ceux de la partie comestible.
- **Prix** : estimations de prix moyens en supermarché en France fin 2026. Suffisant pour comparer les recettes entre elles, pas pour un budget au centime. Pour les mettre à jour, modifier la colonne `prix_achat` de `src/ingredients.psv`.
- **Produits transformés** (cubes de bouillon, pâtes à tarte, pâte de curry) : les allergènes suivent une composition courante, les recettes réelles varient selon les marques.

## Utilisation

### Regénérer après une modification

```bash
python3 scripts/build.py
```

Le script s'arrête et liste les problèmes s'il trouve un ingrédient inconnu, une unité non reconnue, un doublon de titre ou des calories aberrantes.

Format d'une recette dans `src/recettes/*.txt` :

```
## Titre | catégorie | difficulté | prépa (min) | cuisson (min) | portions | cuisine | tag1,tag2
id_ingredient quantité unité (note facultative)
sel qs
- Étape 1.
- Étape 2.
```

Unités : `g kg ml cl l cas cac pincee` et pour les pièces `u gousse tranche botte feuille pot boule rouleau pave filet cube sachet`. `qs` = selon goût.

### Installer dans Supabase

1. Dans l'éditeur SQL du projet Supabase, exécuter `supabase/schema.sql`, puis `supabase/seed.sql`.
2. Déployer la fonction d'import : `supabase functions deploy import-recipe`.

`seed.sql` peut être relancé à chaque mise à jour du catalogue : il met à jour les recettes sans toucher aux likes, menus et recettes importées des utilisateurs.

## Fonctions disponibles côté appli

| Fonction | Rôle |
|---|---|
| `swipe_queue(groupe, nb)` | Recettes à proposer au swipe : pas encore notées, compatibles avec tout le groupe, de saison si le groupe l'a demandé. Celles déjà aimées par les autres membres passent en premier pour favoriser les matchs. |
| `group_matches(groupe, mois)` | Recettes en commun selon la règle du groupe : unanimité, majorité ou seuil en %. |
| `generate_shopping_list(menu)` | Génère la liste de courses d'un menu de la semaine. |
| `join_group(code)` | Rejoindre un groupe avec son code d'invitation. |
| `find_duplicates(titre, url)` | Recettes déjà présentes au même lien ou au titre très proche. |
| `match_ingredient(libellé)` | Associe un libellé libre (« 2 oignons rouges ») au référentiel. |
| `recompute_recipe(id)` | Recalcule coût, nutrition, régimes et saison d'une recette perso ou importée. |

Un like peut venir du swipe ou de la recherche (colonne `source` de la table `swipes`), et on peut revenir sur un avis à tout moment (une ligne par personne et par recette).

## Import d'une recette depuis un lien

La fonction `import-recipe` lit les données structurées schema.org/Recipe que publient la plupart des sites de recettes, puis :

1. refuse le lien s'il a déjà été importé,
2. signale les recettes au titre très proche (l'utilisateur peut forcer l'import),
3. associe chaque ligne d'ingrédient au référentiel, et liste celles qu'il faut associer à la main,
4. calcule coût, calories, régimes et saison.

La recette importée reste privée ou partagée avec le groupe choisi, elle n'entre pas dans le catalogue commun. L'image n'est pas copiée, seuls son lien et l'URL de la page source sont conservés.

## Tests effectués

- Chargement du schéma et du catalogue dans Postgres 16, rechargement du catalogue deux fois de suite.
- Le calcul SQL (`recompute_recipe`) redonne exactement les mêmes résultats que le script Python sur les 503 recettes.
- Scénario complet : création de groupe, invitation, likes, matchs (avec un membre végétarien et un membre allergique), filtre saison, file de swipe, menu, placard, liste de courses.
- Sécurité : un utilisateur extérieur au groupe ne voit ni le groupe ni les avis de ses membres.
- Analyse des lignes d'ingrédients et du JSON-LD testée sur des exemples. La fonction d'import elle-même n'a pas pu être exécutée ici (pas d'accès à des sites externes), à tester après déploiement.
