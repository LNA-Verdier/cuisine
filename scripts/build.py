#!/usr/bin/env python3
"""Construit le catalogue : valide les recettes, calcule les données dérivées
(coût, nutrition par portion, allergènes, régimes, saisonnalité) et exporte
JSON + CSV + SQL de chargement pour Supabase.

Usage : python3 scripts/build.py   (depuis la racine du projet)
"""
import csv, json, math, re, sys, unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC, OUT, SQL = ROOT / "src", ROOT / "data", ROOT / "supabase"

ALLERGENES = {
    "GLU": "Gluten", "CRU": "Crustacés", "OEU": "Œufs", "POI": "Poissons",
    "ARA": "Arachides", "SOJ": "Soja", "LAI": "Lait", "FCO": "Fruits à coque",
    "CEL": "Céleri", "MOU": "Moutarde", "SES": "Sésame", "SUL": "Sulfites",
    "LUP": "Lupin", "MOL": "Mollusques",
}
MARQUEURS = {"V", "P", "Po", "Cr", "L", "O", "M", "A", "G"}
RAYONS = {
    "FL": (1, "Fruits et légumes"), "BOUL": (2, "Boulangerie"),
    "VIA": (3, "Boucherie, volaille"), "CHA": (4, "Charcuterie"),
    "POI": (5, "Poissonnerie"), "CRE": (6, "Crèmerie, frais"),
    "FRO": (7, "Fromages"), "EPS": (8, "Épicerie salée"),
    "CON": (9, "Conserves"), "EPI": (10, "Épices, condiments"),
    "EPC": (11, "Épicerie sucrée"), "SUR": (12, "Surgelés"),
    "BOI": (13, "Boissons"),
}
CATEGORIES = {"entree", "salade", "soupe", "plat", "accompagnement", "dessert", "petit-dej"}
DIFFICULTES = {"facile", "moyen", "difficile"}
# Régimes : marqueurs interdits
REGIMES = {
    "vegane": {"V", "P", "Po", "Cr", "L", "O", "M", "G"},
    "vegetarien": {"V", "P", "Po", "Cr", "G"},
    "pescetarien": {"V", "P", "G"},
    "sans_porc": {"P", "G"},
    "compatible_halal": {"P", "A", "G"},  # sans porc ni alcool (viande halal à acheter)
}
# Unités de recette -> (famille, facteur vers g/ml/u)
UNITES = {
    "g": ("g", 1), "kg": ("g", 1000),
    "ml": ("ml", 1), "cl": ("ml", 10), "l": ("ml", 1000),
    "cas": ("ml", 15), "cac": ("ml", 5), "pincee": ("g", 0.5),
    **{u: ("u", 1) for u in ["u", "gousse", "tranche", "botte", "feuille", "brin",
                             "pot", "boule", "rouleau", "pave", "filet", "cube",
                             "sachet", "piece", "boite", "dose", "branche"]},
}
# Masse approximative d'une cuillère pour les produits secs en poudre (g/ml)
DENSITE_POUDRE = 0.6
SEUIL_SAISON_G = 20


def slug(s):
    s = s.replace("œ", "oe").replace("Œ", "Oe").replace("æ", "ae")
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")


def parse_mois(spec):
    if spec == "":
        return None          # non concerné
    if spec == "*":
        return set(range(1, 13))
    if spec == "0":
        return set()         # jamais de saison
    mois = set()
    for part in spec.split(","):
        a, _, b = part.partition("-")
        a, b = int(a), int(b or a)
        m = a
        while True:
            mois.add(m)
            if m == b:
                break
            m = m % 12 + 1
    return mois


def load_ingredients(errors):
    ings = {}
    for n, line in enumerate((SRC / "ingredients.psv").read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        f = line.split("|")
        if len(f) != 16:
            errors.append(f"ingredients.psv:{n}: {len(f)} champs au lieu de 16 ({f[0]})")
            continue
        (key, nom, rayon, base, dens, pu, aq, alib, prix, kcal, prot, gluc, lip,
         allerg, marq, saison) = f
        if key in ings:
            errors.append(f"ingredients.psv:{n}: clé en double {key}")
        if rayon not in RAYONS:
            errors.append(f"ingredients.psv:{n}: rayon inconnu {rayon}")
        if base not in ("g", "ml", "u"):
            errors.append(f"ingredients.psv:{n}: base inconnue {base}")
        al = [a for a in allerg.split(",") if a]
        mq = [m for m in marq.split(",") if m]
        for a in al:
            if a not in ALLERGENES:
                errors.append(f"ingredients.psv:{n}: allergène inconnu {a} ({key})")
        for m in mq:
            if m not in MARQUEURS:
                errors.append(f"ingredients.psv:{n}: marqueur inconnu {m} ({key})")
        if base == "u" and not pu:
            errors.append(f"ingredients.psv:{n}: poids unitaire requis pour base u ({key})")
        ings[key] = dict(
            id=key, nom=nom, rayon=rayon, rayon_nom=RAYONS.get(rayon, (99, ""))[1],
            rayon_ordre=RAYONS.get(rayon, (99, ""))[0], unite_base=base,
            densite=float(dens) if dens else None, poids_unitaire_g=float(pu) if pu else None,
            achat_quantite=float(aq), achat_libelle=alib, prix_achat_eur=float(prix),
            kcal_100g=float(kcal), proteines_100g=float(prot), glucides_100g=float(gluc),
            lipides_100g=float(lip), allergenes=al, marqueurs=mq,
            saison_spec=saison, saison_mois=sorted(parse_mois(saison)) if parse_mois(saison) is not None else None,
        )
    return ings


def to_grams(ing, qty, unit):
    """Convertit une quantité de recette en grammes (pour la nutrition)."""
    fam, fac = UNITES[unit]
    q = qty * fac
    if fam == "g":
        return q
    if fam == "ml":
        if ing["densite"] is not None:
            return q * ing["densite"]
        if unit in ("cas", "cac") and ing["unite_base"] == "g":
            return q * DENSITE_POUDRE
        return q
    # pièces
    if ing["poids_unitaire_g"] is None:
        raise ValueError(f"pas de poids unitaire pour {ing['id']}")
    return q * ing["poids_unitaire_g"]


def to_base(ing, grams):
    b = ing["unite_base"]
    if b == "g":
        return grams
    if b == "ml":
        return grams / (ing["densite"] or 1)
    return grams / ing["poids_unitaire_g"]


HEADER_RE = re.compile(r"^##\s+(.+)$")
ING_RE = re.compile(r"^([a-z0-9_]+)\s+(qs|[0-9]+(?:[.,][0-9]+)?(?:/[0-9]+)?)\s*([a-z]*)\s*(?:\((.*)\))?\s*$")


def parse_qty(s):
    s = s.replace(",", ".")
    if "/" in s:
        a, b = s.split("/")
        return float(a) / float(b)
    return float(s)


def load_recipes(ings, errors):
    recettes = []
    for path in sorted((SRC / "recettes").glob("*.txt")):
        cur = None
        for n, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            line = raw.strip()
            where = f"{path.name}:{n}"
            if not line or line.startswith("#!"):
                continue
            m = HEADER_RE.match(line)
            if m:
                parts = [p.strip() for p in m.group(1).split("|")]
                if len(parts) != 8:
                    errors.append(f"{where}: en-tête à 8 champs attendu : {line}")
                    cur = None
                    continue
                titre, cat, diff, prep, cuis, pers, cuisine, tags = parts
                if cat not in CATEGORIES:
                    errors.append(f"{where}: catégorie inconnue {cat}")
                if diff not in DIFFICULTES:
                    errors.append(f"{where}: difficulté inconnue {diff}")
                cur = dict(titre=titre, categorie=cat, difficulte=diff,
                           temps_preparation_min=int(prep), temps_cuisson_min=int(cuis),
                           portions=int(pers), cuisine=cuisine,
                           tags=[t.strip() for t in tags.split(",") if t.strip()],
                           ingredients=[], etapes=[], source=f"{path.name}:{n}")
                recettes.append(cur)
                continue
            if cur is None:
                errors.append(f"{where}: ligne hors recette")
                continue
            if line.startswith("- "):
                cur["etapes"].append(line[2:].strip())
                continue
            m = ING_RE.match(line)
            if not m:
                errors.append(f"{where}: ligne illisible : {line}")
                continue
            key, q, unit, note = m.groups()
            if key not in ings:
                errors.append(f"{where}: ingrédient inconnu {key}")
                continue
            if q == "qs":
                cur["ingredients"].append(dict(id=key, quantite=None, unite=None, note=note))
                continue
            unit = unit or "u"
            if unit not in UNITES:
                errors.append(f"{where}: unité inconnue {unit}")
                continue
            cur["ingredients"].append(dict(id=key, quantite=parse_qty(q), unite=unit, note=note))
    return recettes


def enrich(r, ings, errors):
    tot = dict(kcal=0.0, prot=0.0, gluc=0.0, lip=0.0, cout=0.0)
    allerg, marq = set(), set()
    mois = set(range(1, 13))
    for li in r["ingredients"]:
        ing = ings[li["id"]]
        allerg.update(ing["allergenes"])
        marq.update(ing["marqueurs"])
        if li["quantite"] is None:
            li.update(grammes=None, quantite_base=None)
            continue
        try:
            g = to_grams(ing, li["quantite"], li["unite"])
        except ValueError as e:
            errors.append(f"{r['source']}: {e}")
            continue
        base = to_base(ing, g)
        sm = ing["saison_mois"]
        # Saisonnalité : seuls les fruits et légumes « principaux » comptent
        # (aromates et condiments sous SEUIL_SAISON_G g par personne ignorés)
        if sm is not None and g / r["portions"] >= SEUIL_SAISON_G:
            mois &= set(sm)
        li.update(grammes=round(g, 1), quantite_base=round(base, 3))
        k = g / 100
        tot["kcal"] += ing["kcal_100g"] * k
        tot["prot"] += ing["proteines_100g"] * k
        tot["gluc"] += ing["glucides_100g"] * k
        tot["lip"] += ing["lipides_100g"] * k
        tot["cout"] += base / ing["achat_quantite"] * ing["prix_achat_eur"]
    p = r["portions"]
    r["id"] = slug(r["titre"])
    r["temps_total_min"] = r["temps_preparation_min"] + r["temps_cuisson_min"]
    r["kcal_portion"] = round(tot["kcal"] / p)
    r["proteines_portion_g"] = round(tot["prot"] / p, 1)
    r["glucides_portion_g"] = round(tot["gluc"] / p, 1)
    r["lipides_portion_g"] = round(tot["lip"] / p, 1)
    r["cout_total_eur"] = round(tot["cout"], 2)
    r["cout_portion_eur"] = round(tot["cout"] / p, 2)
    r["allergenes"] = sorted(allerg)
    r["regimes"] = [k for k, interdits in REGIMES.items() if not (marq & interdits)]
    if "GLU" not in allerg:
        r["regimes"].append("sans_gluten")
    if "LAI" not in allerg:
        r["regimes"].append("sans_lactose")
    r["contient_alcool"] = "A" in marq
    r["mois_saison"] = sorted(mois)
    r["toute_annee"] = len(mois) == 12
    if r["kcal_portion"] < 40 or r["kcal_portion"] > 1500:
        errors.append(f"{r['source']}: kcal/portion suspect ({r['kcal_portion']}) pour {r['titre']}")
    if not r["etapes"] or not r["ingredients"]:
        errors.append(f"{r['source']}: recette incomplète {r['titre']}")
    del r["source"]
    return r


def sql_str(v):
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, list):
        if all(isinstance(x, int) for x in v):
            return "'{" + ",".join(str(x) for x in v) + "}'::int[]"
        return "array[" + ",".join(sql_str(x) for x in v) + "]::text[]" if v else "'{}'::text[]"
    return "'" + str(v).replace("'", "''") + "'"


def write_sql(ings, recettes):
    # Chargement idempotent : met à jour le catalogue sans toucher aux données des utilisateurs
    out = ["-- Généré par scripts/build.py : catalogue de référence (rechargeable sans perte de données)", "begin;"]
    cols = ["id", "nom", "rayon", "rayon_nom", "rayon_ordre", "unite_base", "densite",
            "poids_unitaire_g", "achat_quantite", "achat_libelle", "prix_achat_eur",
            "kcal_100g", "proteines_100g", "glucides_100g", "lipides_100g",
            "allergenes", "marqueurs", "saison_mois"]
    for i in ings.values():
        out.append(f"insert into ingredients ({','.join(cols)}) values ({','.join(sql_str(i[c]) for c in cols)})"
                   f" on conflict (id) do update set ({','.join(cols[1:])}) = ({','.join('excluded.' + c for c in cols[1:])});")
    out.append("delete from recipe_ingredients where recipe_id in (select id from recipes where origine = 'catalogue');")
    rcols = ["id", "titre", "categorie", "difficulte", "temps_preparation_min", "temps_cuisson_min",
             "temps_total_min", "portions", "cuisine", "tags", "etapes", "kcal_portion",
             "proteines_portion_g", "glucides_portion_g", "lipides_portion_g", "cout_total_eur",
             "cout_portion_eur", "allergenes", "regimes", "contient_alcool", "mois_saison", "toute_annee"]
    for r in recettes:
        vals = [sql_str(r[c]) for c in rcols]
        out.append(f"insert into recipes ({','.join(rcols)}, origine) values ({','.join(vals)}, 'catalogue')"
                   f" on conflict (id) do update set ({','.join(rcols[1:])}) = ({','.join('excluded.' + c for c in rcols[1:])});")
        for pos, li in enumerate(r["ingredients"]):
            out.append("insert into recipe_ingredients (recipe_id, position, ingredient_id, quantite, unite, quantite_base, grammes, note) values ("
                       + ",".join(sql_str(x) for x in [r["id"], pos, li["id"], li["quantite"], li["unite"],
                                                       li["quantite_base"], li["grammes"], li["note"]]) + ");")
    out.append("commit;")
    (SQL / "seed.sql").write_text("\n".join(out) + "\n", encoding="utf-8")


def main():
    errors = []
    ings = load_ingredients(errors)
    recettes = load_recipes(ings, errors)
    seen = {}
    for r in recettes:
        enrich(r, ings, errors)
        if r["id"] in seen:
            errors.append(f"doublon de titre : {r['titre']}")
        seen[r["id"]] = r
    if errors:
        print("\n".join(errors[:200]))
        print(f"\n{len(errors)} problème(s)")
        sys.exit(1)
    OUT.mkdir(exist_ok=True)
    SQL.mkdir(exist_ok=True)
    (OUT / "ingredients.json").write_text(json.dumps(list(ings.values()), ensure_ascii=False, indent=1), encoding="utf-8")
    (OUT / "recettes.json").write_text(json.dumps(recettes, ensure_ascii=False, indent=1), encoding="utf-8")
    with open(OUT / "recettes.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["id", "titre", "categorie", "difficulte", "temps_total_min", "portions", "cuisine",
                    "kcal_portion", "cout_portion_eur", "regimes", "allergenes", "mois_saison", "tags"])
        for r in recettes:
            w.writerow([r["id"], r["titre"], r["categorie"], r["difficulte"], r["temps_total_min"],
                        r["portions"], r["cuisine"], r["kcal_portion"], r["cout_portion_eur"],
                        " ".join(r["regimes"]), " ".join(r["allergenes"]),
                        " ".join(map(str, r["mois_saison"])), " ".join(r["tags"])])
    write_sql(ings, recettes)
    print(f"OK : {len(ings)} ingrédients, {len(recettes)} recettes")


if __name__ == "__main__":
    main()
