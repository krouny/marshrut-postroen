// Supabase Edge Function: generate-plan
// Вызывает настоящую модель Claude, чтобы собрать конкретный, исследованный план
// поездки (реальные названия ресторанов/мест, честный совет по логистике) —
// вместо шаблонного генератора на клиенте (см. buildPlan() в index.html).
//
// АГЕНТНЫЙ РЕЖИМ: модели даётся инструмент веб-поиска (серверный tool от Anthropic).
// Она сама решает, что и сколько раз погуглить (актуальные места, паромы/дороги,
// сезонность), прежде чем собрать итоговый план — а не просто вспоминает по памяти.
// Это дороже и медленнее одиночного вызова, зато меньше шанс устаревших/выдуманных мест.
//
// Ключ ANTHROPIC_API_KEY хранится ТОЛЬКО здесь, на сервере — в браузер не попадает.
//
// Деплой:
//   supabase functions deploy generate-plan
//   supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
//
// Вызов с клиента: sb.functions.invoke('generate-plan', { body: {...} })

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY");
const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY");

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

// Серверный инструмент веб-поиска Anthropic — выполняется на их стороне,
// не нужно самим ходить в поисковик и присылать результаты обратно.
const WEB_SEARCH_TOOL = {
  type: "web_search_20250305",
  name: "web_search",
  max_uses: 8,
};

// Схема плана — та же форма, что уже понимает renderPlan() на клиенте,
// чтобы не переписывать вёрстку под новый формат.
const PLAN_TOOL = {
  name: "return_travel_plan",
  description: "Вернуть уже готовый, проверенный план поездки в строгом формате. Вызывать только после того, как нужные места и логистика проверены поиском.",
  input_schema: {
    type: "object",
    required: ["intro", "typeLabel", "stayText", "days"],
    properties: {
      intro: {
        type: "string",
        description: "1-2 предложения: для кого план, что за направление, ключевая логистическая мысль (например «сюда удобнее лететь и дальше на машине» или «лучше остаться в одном городе, дальние переезды не оправданы»).",
      },
      typeLabel: {
        type: "string",
        description: "Короткая метка направления с эмодзи, например «🏝 Пляж / острова», «⛰ Горы», «🏙 Город».",
      },
      stayText: {
        type: "string",
        description: "Конкретная рекомендация по жилью под бюджет и состав группы — с районом/типом отеля, если это известно про данное место.",
      },
      days: {
        type: "array",
        description: "План по дням, ровно столько дней, сколько запрошено.",
        items: {
          type: "object",
          required: ["title", "items"],
          properties: {
            title: { type: "string", description: "Короткий заголовок дня, 2-5 слов." },
            items: {
              type: "array",
              items: {
                type: "object",
                required: ["w", "t"],
                properties: {
                  w: { type: "string", description: "Время суток: Утро / День / Вечер, или конкретное время вроде '10:00', если это уместно." },
                  t: {
                    type: "string",
                    description: "Конкретный пункт плана. По возможности — реальное название места/ресторана/маршрута, известное про этот город, и практический совет (например, время работы, стоит ли ехать на машине, есть ли толпы). Если ты не уверен в актуальности конкретного места — предложи тип места без выдуманного названия, а не рискуй ошибочным фактом.",
                  },
                },
              },
            },
          },
        },
      },
    },
  },
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST") return jsonResponse({ error: "method_not_allowed" }, 405);

  if (!ANTHROPIC_API_KEY) {
    return jsonResponse({ error: "not_configured", message: "ANTHROPIC_API_KEY не задан на сервере" }, 503);
  }

  // Проверяем, что пользователь реально вошёл и у него платный тариф —
  // ИИ-вызов стоит денег за каждый запрос, бесплатным пользователям сюда нельзя.
  const authHeader = req.headers.get("Authorization") || "";
  if (!authHeader) return jsonResponse({ error: "unauthorized" }, 401);

  let userId: string | null = null;
  try {
    const supabase = createClient(SUPABASE_URL!, SUPABASE_ANON_KEY!, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userErr } = await supabase.auth.getUser();
    if (userErr || !userData?.user) return jsonResponse({ error: "unauthorized" }, 401);
    userId = userData.user.id;

    const { data: profile } = await supabase.from("profiles").select("tier").eq("id", userId).maybeSingle();
    const tier = profile?.tier || "free";
    if (tier === "free") {
      return jsonResponse({ error: "payment_required", message: "ИИ-планировщик доступен с тарифа «Путешественник»" }, 402);
    }
  } catch (_e) {
    return jsonResponse({ error: "auth_check_failed" }, 401);
  }

  let body: any;
  try {
    body = await req.json();
  } catch (_e) {
    return jsonResponse({ error: "bad_request" }, 400);
  }

  const {
    city, country, days, people, withWhom, budget, budgetSum,
    interests, notes, startDate, nearbySettlements,
  } = body || {};

  if (!city || !days) return jsonResponse({ error: "missing_fields" }, 400);

  const daysNum = Math.max(1, Math.min(21, parseInt(days) || 3));
  const withWhomText: Record<string, string> = {
    "один": "путешествует один/одна",
    "пара": "поездка вдвоём, романтика",
    "семья": "семья с детьми — учитывай безопасность и подходящие детям активности",
    "друзья": "компания друзей",
    "компания": "большая компания",
  };

  const groundingLines: string[] = [];
  if (Array.isArray(nearbySettlements) && nearbySettlements.length) {
    groundingLines.push(
      "Проверенные реальные расстояния на машине от " + city + " (используй именно эти цифры, не выдумывай свои):",
    );
    for (const s of nearbySettlements) {
      groundingLines.push(`— ${s.name}: ${s.km} км, ≈${s.min} мин на машине`);
    }
  }

  const prompt = `Ты — travel-консьерж, который лично готовит подробный план поездки, как для реального клиента.
Составь план по дням в направление: ${city}${country ? ", " + country : ""}.

Параметры поездки:
— Длительность: ${daysNum} дней${startDate ? ", начало " + startDate : ""}
— Состав: ${withWhomText[withWhom] || withWhom || "не указано"}, ${people || 1} человек
— Бюджет: ${budgetSum ? budgetSum + " ₽ на всех на всю поездку (уровень «" + budget + "»)" : "уровень «" + budget + "»"}
— Интересы: ${(interests || []).join(", ") || "не указаны, подбери сбалансированно"}
— Пожелания от клиента: ${notes || "нет особых пожеланий"}

${groundingLines.join("\n")}

Требования к плану:
1. Прежде чем писать конкретные названия (рестораны, пляжи, экскурсии, конкретные маршруты) —
   ПРОВЕРЬ их через веб-поиск: они должны реально существовать и по возможности всё ещё работать.
   Если после поиска не уверен в конкретном месте — опиши тип места честно ("рыбный ресторан у гавани")
   без вымышленного бренда, лучше честно, чем красиво и неточно.
2. Поищи и честно учти логистику: стоит ли брать машину, есть ли смысл выезжать в соседние города
   (используй проверенные расстояния выше, если они даны), паромы/сезонные ограничения/ремонты дорог,
   что лучше не делать (например «в этот пляж лучше не ехать в выходные — не будет мест на парковке»).
3. Учитывай состав группы (дети, пара, компания) в выборе активностей.
4. Первый день — обычно прилёт/заселение, последний — сборы/отъезд, без насыщенной программы.
5. Пиши по-русски, тепло и по-человечески, как заботливый друг, а не как рекламный буклет.
6. Не обещай бронирование или цены, которых ты не можешь знать точно — только реальные рекомендации.
7. Когда исследование закончено — вызови return_travel_plan с готовым планом. Пока не уверен, что
   проверил ключевые места и логистику через поиск — не вызывай его.`;

  // Общий вызов Anthropic Messages API
  async function callClaude(messages: any[], tools: any[], toolChoice?: any) {
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": ANTHROPIC_API_KEY!,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: "claude-sonnet-4-5",
        max_tokens: 8192,
        tools,
        ...(toolChoice ? { tool_choice: toolChoice } : {}),
        messages,
      }),
    });
    if (!res.ok) {
      const errText = await res.text();
      console.error("Anthropic API error:", res.status, errText);
      throw new Error("ai_error_" + res.status);
    }
    return res.json();
  }

  try {
    // Шаг 1: даём модели волю искать в интернете (auto — иначе форс конкретного
    // tool заблокировал бы возможность сначала погуглить). Модель может сделать
    // несколько поисков подряд — это всё разворачивается на стороне Anthropic.
    let messages: any[] = [{ role: "user", content: prompt }];
    let aiData = await callClaude(messages, [WEB_SEARCH_TOOL, PLAN_TOOL]);

    // pause_turn — сервер просит продолжить тот же ход (долгая цепочка поисков),
    // просто отправляем его же ответ обратно без нового пользовательского сообщения
    let guard = 0;
    while (aiData.stop_reason === "pause_turn" && guard < 5) {
      messages = [...messages, { role: "assistant", content: aiData.content }];
      aiData = await callClaude(messages, [WEB_SEARCH_TOOL, PLAN_TOOL]);
      guard++;
    }

    let toolUse = (aiData.content || []).find((c: any) => c.type === "tool_use" && c.name === "return_travel_plan");

    // Модель могла закончить исследование текстом, не вызвав финальный tool —
    // просим явно оформить результат, на этот раз форсируя нужный tool
    // (форсировать безопасно: поиск уже проведён в предыдущих ходах).
    if (!toolUse) {
      messages = [
        ...messages,
        { role: "assistant", content: aiData.content },
        { role: "user", content: "Заверши задачу: оформи итоговый план строго вызовом return_travel_plan, используя всё, что нашёл выше." },
      ];
      aiData = await callClaude(messages, [PLAN_TOOL], { type: "tool", name: "return_travel_plan" });
      toolUse = (aiData.content || []).find((c: any) => c.type === "tool_use" && c.name === "return_travel_plan");
    }

    if (!toolUse) return jsonResponse({ error: "no_structured_output" }, 502);

    const plan = toolUse.input;
    // Прикрепляем номер дня и (если есть) дату — считаем на сервере, не доверяем модели даты
    const WD = ["Вс", "Пн", "Вт", "Ср", "Чт", "Пт", "Сб"];
    const startD = startDate ? new Date(startDate + "T00:00:00") : null;
    plan.days = (plan.days || []).slice(0, daysNum).map((d: any, i: number) => {
      let dateLabel = null;
      if (startD) {
        const dd = new Date(startD.getTime() + i * 86400000);
        dateLabel = String(dd.getDate()).padStart(2, "0") + "." + String(dd.getMonth() + 1).padStart(2, "0") + ", " + WD[dd.getDay()];
      }
      return { n: i + 1, title: d.title, items: d.items || [], date: dateLabel };
    });

    return jsonResponse({ plan, source: "ai" });
  } catch (e) {
    console.error("generate-plan error:", e);
    return jsonResponse({ error: "internal_error" }, 500);
  }
});
