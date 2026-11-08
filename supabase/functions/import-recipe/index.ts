// Edge Function Supabase : importer une recette depuis un lien.
// Déploiement : supabase functions deploy import-recipe
// Appel (côté appli) : supabase.functions.invoke("import-recipe", { body: { url, groupe_id, force } })
//
// La recette importée reste privée (ou partagée avec le groupe choisi) : elle n'entre pas
// dans le catalogue commun. On ne copie pas l'image, on garde seulement son lien et l'URL source.

import { createClient } from "jsr:@supabase/supabase-js@2";
import { analyserLigne, extraireRecette, slugifier } from "./parse.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const SEUIL_DOUBLON = 0.85;   // similarité de titre au-delà de laquelle on demande confirmation
const SEUIL_INGREDIENT = 0.45; // en dessous, l'ingrédient est à associer à la main

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return json({ erreur: "non connecté" }, 401);

  const { url, groupe_id = null, force = false } = await req.json().catch(() => ({}));
  if (!url || !/^https?:\/\//i.test(url)) return json({ erreur: "lien invalide" }, 400);

  const { data: imp } = await supabase.from("recipe_imports").insert({ user_id: user.id, url }).select().single();
  const finir = async (statut: string, extra: Record<string, unknown> = {}) => {
    await supabase.from("recipe_imports").update({
      statut, recipe_id: extra.recipe_id ?? null, message: extra.message ?? null,
    }).eq("id", imp?.id);
    return json({ statut, ...extra });
  };

  // 1. Même lien déjà importé ?
  const { data: memeLien } = await supabase.rpc("find_duplicates", { p_titre: "", p_url: url });
  const dejaLa = (memeLien ?? []).find((d: any) => d.meme_url);
  if (dejaLa) return finir("doublon", { recipe_id: dejaLa.recipe_id, message: `Déjà dans la base : ${dejaLa.titre}` });

  // 2. Lecture de la page
  let html: string;
  try {
    const rep = await fetch(url, {
      headers: { "User-Agent": "Mozilla/5.0 (compatible; RecettesApp/1.0)", "Accept-Language": "fr-FR,fr" },
      signal: AbortSignal.timeout(10_000),
    });
    if (!rep.ok) return finir("erreur", { message: `La page a répondu ${rep.status}` });
    html = await rep.text();
  } catch (e) {
    return finir("erreur", { message: `Page inaccessible : ${e}` });
  }
  const rec = extraireRecette(html);
  if (!rec || !rec.titre || rec.ingredients.length === 0) {
    return finir("erreur", { message: "Aucune recette structurée trouvée sur cette page (schema.org/Recipe)." });
  }

  // 3. Recette au titre très proche déjà présente ?
  if (!force) {
    const { data: proches } = await supabase.rpc("find_duplicates", { p_titre: rec.titre, p_url: null });
    const candidats = (proches ?? []).filter((d: any) => d.similarite >= SEUIL_DOUBLON);
    if (candidats.length) {
      return finir("doublon", {
        message: "Une recette très proche existe déjà. Relancer avec force=true pour l'importer quand même.",
        candidats,
      });
    }
  }

  // 4. Association des ingrédients au référentiel
  const lignes = [];
  const nonReconnus: string[] = [];
  for (const brute of rec.ingredients) {
    const l = analyserLigne(brute);
    const { data: m } = await supabase.rpc("match_ingredient", { libelle: l.nom });
    const meilleur = m?.[0];
    if (!meilleur || meilleur.score < SEUIL_INGREDIENT) {
      nonReconnus.push(brute);
      continue;
    }
    lignes.push({ ...l, ingredient_id: meilleur.ingredient_id });
  }

  // 5. Enregistrement
  const id = `${slugifier(rec.titre).slice(0, 60)}-${crypto.randomUUID().slice(0, 6)}`;
  const { error: e1 } = await supabase.from("recipes").insert({
    id, titre: rec.titre, categorie: rec.categorie, difficulte: "moyen",
    temps_preparation_min: rec.prepMin, temps_cuisson_min: rec.cuissonMin,
    temps_total_min: rec.prepMin + rec.cuissonMin, portions: rec.portions,
    cuisine: rec.cuisine ?? null, etapes: rec.etapes, image_url: rec.image ?? null,
    origine: "import", source_url: url, cree_par: user.id, groupe_id,
  });
  if (e1) return finir("erreur", { message: e1.message });

  const { error: e2 } = await supabase.from("recipe_ingredients").insert(
    lignes.map((l, position) => ({
      recipe_id: id, position, ingredient_id: l.ingredient_id,
      quantite: l.quantite, unite: l.unite, note: l.ligne,
    })),
  );
  if (e2) return finir("erreur", { recipe_id: id, message: e2.message });

  // 6. Calcul du coût, des calories, des régimes et de la saison
  const { data: recette } = await supabase.rpc("recompute_recipe", { rid: id });

  return nonReconnus.length
    ? finir("a_verifier", {
        recipe_id: id, recette,
        message: `Ingrédients à associer à la main : ${nonReconnus.join(" · ")}`,
        non_reconnus: nonReconnus,
      })
    : finir("ok", { recipe_id: id, recette });
});
