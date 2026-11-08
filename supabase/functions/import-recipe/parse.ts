// Analyse d'une page de recette : lecture des données structurées schema.org/Recipe (JSON-LD),
// que publient la plupart des sites de recettes, et découpage des lignes d'ingrédients.

export type RecetteBrute = {
  titre: string;
  portions: number;
  prepMin: number;
  cuissonMin: number;
  ingredients: string[];
  etapes: string[];
  image?: string;
  categorie: string;
  cuisine?: string;
};

export type LigneIngredient = {
  ligne: string;
  quantite: number | null; // null = selon goût
  unite: string | null;    // codes de l'appli : g, kg, ml, cl, l, cas, cac, pincee, u, gousse...
  nom: string;
};

// ---------- JSON-LD ----------
function* objetsJsonLd(html: string): Generator<any> {
  const re = /<script[^>]*type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi;
  let m: RegExpExecArray | null;
  while ((m = re.exec(html))) {
    try {
      yield* aplatir(JSON.parse(m[1].trim()));
    } catch { /* bloc JSON invalide : on ignore */ }
  }
}

function* aplatir(x: any): Generator<any> {
  if (Array.isArray(x)) for (const y of x) yield* aplatir(y);
  else if (x && typeof x === "object") {
    yield x;
    if (x["@graph"]) yield* aplatir(x["@graph"]);
  }
}

const estRecette = (o: any) => {
  const t = o["@type"];
  return t === "Recipe" || (Array.isArray(t) && t.includes("Recipe"));
};

export function dureeIsoEnMinutes(d?: string): number {
  if (!d || typeof d !== "string") return 0;
  const m = d.match(/P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?/i);
  if (!m) return 0;
  return (+(m[1] || 0)) * 1440 + (+(m[2] || 0)) * 60 + (+(m[3] || 0));
}

function texte(x: any): string {
  return String(x ?? "").replace(/<[^>]+>/g, " ").replace(/&nbsp;/g, " ").replace(/&amp;/g, "&")
    .replace(/&#0?39;|&apos;/g, "'").replace(/&quot;/g, '"').replace(/\s+/g, " ").trim();
}

function etapes(x: any): string[] {
  if (!x) return [];
  if (typeof x === "string") return x.split(/\n+|(?<=\.)\s+(?=\d+[.)]\s)/).map(texte).filter(Boolean);
  if (Array.isArray(x)) return x.flatMap(etapes);
  if (x.itemListElement) return etapes(x.itemListElement); // HowToSection
  if (x.text) return [texte(x.text)];                     // HowToStep
  if (x.name) return [texte(x.name)];
  return [];
}

const CATEGORIES: [RegExp, string][] = [
  [/dessert|g[aâ]teau|tarte sucr|p[aâ]tisserie|go[uû]ter/i, "dessert"],
  [/petit[- ]d[eé]j|brunch|breakfast/i, "petit-dej"],
  [/soupe|velout[eé]|potage/i, "soupe"],
  [/salade/i, "salade"],
  [/entr[eé]e|ap[eé]ritif|amuse/i, "entree"],
  [/accompagnement|side/i, "accompagnement"],
];

export function extraireRecette(html: string): RecetteBrute | null {
  for (const o of objetsJsonLd(html)) {
    if (!estRecette(o)) continue;
    const rendement = Array.isArray(o.recipeYield) ? o.recipeYield.join(" ") : String(o.recipeYield ?? "");
    const portions = parseInt(rendement.match(/\d+/)?.[0] ?? "4", 10) || 4;
    const cat = [o.recipeCategory, o.name].flat().filter(Boolean).join(" ");
    const image = Array.isArray(o.image) ? o.image[0] : o.image;
    return {
      titre: texte(o.name),
      portions,
      prepMin: dureeIsoEnMinutes(o.prepTime),
      cuissonMin: dureeIsoEnMinutes(o.cookTime) ||
        Math.max(0, dureeIsoEnMinutes(o.totalTime) - dureeIsoEnMinutes(o.prepTime)),
      ingredients: (o.recipeIngredient ?? o.ingredients ?? []).map(texte).filter(Boolean),
      etapes: etapes(o.recipeInstructions),
      image: typeof image === "string" ? image : image?.url,
      categorie: CATEGORIES.find(([re]) => re.test(cat))?.[1] ?? "plat",
      cuisine: Array.isArray(o.recipeCuisine) ? o.recipeCuisine[0] : o.recipeCuisine,
    };
  }
  return null;
}

// ---------- Lignes d'ingrédients ----------
const FRACTIONS: Record<string, number> = { "½": 0.5, "¼": 0.25, "¾": 0.75, "⅓": 1 / 3, "⅔": 2 / 3 };

// Unités reconnues (ordre important : les plus longues d'abord)
const UNITES: [RegExp, string, number][] = [
  [/^(cuill[eè]res?|c\.?)\s*(?:[aà]|a)\s*soupe(?![a-zà-ÿ])|^c\.?\s*s\.?(?![a-zà-ÿ])|^cs(?![a-zà-ÿ])|^cas(?![a-zà-ÿ])/i, "cas", 1],
  [/^(cuill[eè]res?|c\.?)\s*(?:[aà]|a)\s*caf[eé](?![a-zà-ÿ])|^c\.?\s*c\.?(?![a-zà-ÿ])|^cc(?![a-zà-ÿ])|^cac(?![a-zà-ÿ])/i, "cac", 1],
  [/^kilos?(?![a-zà-ÿ])|^kg(?![a-zà-ÿ])/i, "kg", 1],
  [/^grammes?(?![a-zà-ÿ])|^gr?(?![a-zà-ÿ])/i, "g", 1],
  [/^litres?(?![a-zà-ÿ])|^l(?![a-zà-ÿ])/i, "l", 1],
  [/^dl(?![a-zà-ÿ])/i, "cl", 10],
  [/^cl(?![a-zà-ÿ])/i, "cl", 1],
  [/^ml(?![a-zà-ÿ])/i, "ml", 1],
  [/^verres?(?![a-zà-ÿ])/i, "cl", 20],
  [/^tasses?(?![a-zà-ÿ])|^bols?(?![a-zà-ÿ])/i, "cl", 25],
  [/^pinc[eé]es?(?![a-zà-ÿ])/i, "pincee", 1],
  [/^gousses?(?![a-zà-ÿ])/i, "gousse", 1],
  [/^tranches?(?![a-zà-ÿ])/i, "tranche", 1],
  [/^bottes?(?![a-zà-ÿ])|^bouquets?(?![a-zà-ÿ])/i, "botte", 1],
  [/^feuilles?(?![a-zà-ÿ])/i, "feuille", 1],
  [/^brins?(?![a-zà-ÿ])/i, "brin", 1],
  [/^sachets?(?![a-zà-ÿ])/i, "sachet", 1],
  [/^bo[iî]tes?(?![a-zà-ÿ])/i, "boite", 1],
  [/^pots?(?![a-zà-ÿ])/i, "pot", 1],
  [/^rouleaux?(?![a-zà-ÿ])/i, "rouleau", 1],
  [/^pav[eé]s?(?![a-zà-ÿ])/i, "pave", 1],
  [/^filets?(?![a-zà-ÿ])/i, "filet", 1],
  [/^cubes?(?![a-zà-ÿ])/i, "cube", 1],
  [/^boules?(?![a-zà-ÿ])/i, "boule", 1],
];

export function analyserLigne(ligne: string): LigneIngredient {
  let s = ligne.replace(/\([^)]*\)/g, " ").replace(/\s+/g, " ").trim();
  for (const [f, v] of Object.entries(FRACTIONS)) s = s.replace(f, ` ${v} `);
  s = s.replace(/\s+/g, " ").trim();
  let quantite: number | null = null;
  const q = s.match(/^(\d+(?:[.,]\d+)?)(?:\s*\/\s*(\d+))?(?:\s+(\d+)\/(\d+))?\s*(?:à|-)?\s*(?:\d+(?:[.,]\d+)?)?\s*/);
  if (q && q[0].trim()) {
    quantite = parseFloat(q[1].replace(",", "."));
    if (q[2]) quantite = quantite / parseInt(q[2], 10);
    if (q[3] && q[4]) quantite += parseInt(q[3], 10) / parseInt(q[4], 10);
    s = s.slice(q[0].length);
  } else if (/^(un|une)\b/i.test(s)) {
    quantite = 1;
    s = s.replace(/^(un|une)\s+/i, "");
  }
  let unite: string | null = quantite === null ? null : "u";
  for (const [re, code, facteur] of UNITES) {
    const m = s.match(re);
    if (m) {
      unite = code;
      if (quantite === null) quantite = 1;
      quantite *= facteur;
      s = s.slice(m[0].length).trim();
      break;
    }
  }
  const nom = s
    .replace(/^(de |d'|d’|des |du |de la |de l'|de l’)/i, "")
    .replace(/,.*$/, "")                         // « oignon, émincé » -> « oignon »
    .replace(/\b(environ|bien|bonne?s?|gros(ses?)?|petite?s?|moyen(ne)?s?)\b/gi, "")
    .replace(/\s+/g, " ").trim();
  if (/selon (le )?go[uû]t|^sel\b|^poivre\b/i.test(nom) && quantite === null) {
    return { ligne, quantite: null, unite: null, nom };
  }
  return { ligne, quantite, unite, nom };
}

export function slugifier(t: string): string {
  return t.replace(/œ/g, "oe").replace(/æ/g, "ae").normalize("NFKD").replace(/[̀-ͯ]/g, "")
    .toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
}
