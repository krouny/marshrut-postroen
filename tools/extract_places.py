#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Извлечение названий мест из скриншотов Instagram/TikTok через Gemini Vision.

Часть теста «Волшебник страны Оз»: пользователь присылает в Telegram скриншоты
с местами, которые хочет посетить, — этот скрипт вместо ручного разглядывания
каждого скриншота отдаёт готовый список мест за секунды.

УСТАНОВКА (один раз):
    pip install google-genai

КЛЮЧ API (бесплатно, один раз):
    1. Открой https://aistudio.google.com/apikey
    2. Нажми "Create API key"
    3. Установи ключ как переменную окружения:
         Windows (PowerShell):  $env:GEMINI_API_KEY = "твой_ключ"
         Windows (cmd):         set GEMINI_API_KEY=твой_ключ
       Либо просто впиши его в переменную API_KEY_FALLBACK ниже (для быстрого
       локального теста — но для реальной работы переменная окружения безопаснее,
       файл может случайно попасть в git).

ЗАПУСК:
    Сложи скриншоты в папку screenshots/ рядом со скриптом и запусти:
        python extract_places.py

    Или укажи свою папку:
        python extract_places.py C:\\путь\\к\\скриншотам

РЕЗУЛЬТАТ:
    - places.json      — машиночитаемый список мест (для передачи в сайт/бота)
    - places_report.txt — человекочитаемый отчёт с готовыми ссылками на карты
"""

import os
import sys
import json
import time
import urllib.parse

# На Windows консоль по умолчанию в cp1251 — падает на любых не-ASCII символах
# (кавычки-ёлочки, ×, эмодзи). Переключаем вывод на UTF-8, чтобы не крашилось.
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

API_KEY_FALLBACK = ""  # для быстрого локального теста; лучше используй переменную окружения GEMINI_API_KEY
MODEL = "gemini-3.7-flash"  # актуальная быстрая/дешёвая модель с поддержкой изображений (проверено по докам Google, авг. 2026)
SUPPORTED_EXT = (".jpg", ".jpeg", ".png", ".webp", ".gif")

PROMPT = """Ты анализируешь скриншот из Instagram или TikTok, который пользователь
сохранил как идею места для посещения в путешествии.

Определи:
1. Конкретные названия мест — рестораны, кафе, достопримечательности, отели,
   пляжи, магазины и т.д. Ищи их в подписи под фото/видео, геотеге, хэштегах
   или на самом изображении (вывеска, текст поверх видео).
2. Город и страну, если это можно определить по контексту.

ВАЖНО: если не уверен в названии места — не придумывай его. Лучше вернуть
пустой список, чем ложное название.

Ответь СТРОГО в формате JSON, без markdown-разметки, без пояснений вокруг:
{
  "places": [{"name": "точное название места", "type": "ресторан/кафе/достопримечательность/отель/пляж/другое"}],
  "city": "город или null",
  "country": "страна или null",
  "confidence": "high/medium/low"
}"""


def get_client():
    try:
        from google import genai
    except ImportError:
        sys.exit("Не установлена библиотека. Выполни: pip install google-genai")

    api_key = os.environ.get("GEMINI_API_KEY") or API_KEY_FALLBACK
    if not api_key:
        sys.exit(
            "Нет ключа API. Получи бесплатный ключ на https://aistudio.google.com/apikey\n"
            "и установи его: $env:GEMINI_API_KEY = \"твой_ключ\"  (PowerShell)"
        )
    return genai.Client(api_key=api_key)


def extract_json(text):
    """Модель иногда оборачивает JSON в ```json ... ``` — снимаем обёртку."""
    text = text.strip()
    if text.startswith("```"):
        text = text.split("```")[1]
        if text.startswith("json"):
            text = text[4:]
    return json.loads(text.strip())


def analyze_image(client, path):
    uploaded = client.files.upload(file=path)
    interaction = client.interactions.create(
        model=MODEL,
        input=[
            {"type": "text", "text": PROMPT},
            {"type": "image", "uri": uploaded.uri, "mime_type": uploaded.mime_type},
        ],
    )
    return extract_json(interaction.output_text)


def maps_link(place_name, city):
    query = place_name + (", " + city if city else "")
    return "https://www.google.com/maps/search/" + urllib.parse.quote(query)


def site_link(city):
    """Ссылка на готовый поиск в самом Маршрут Построен для найденного города."""
    if not city:
        return None
    return "https://markizy-trravel.netlify.app/#city=" + urllib.parse.quote(city)


def main():
    folder = sys.argv[1] if len(sys.argv) > 1 else "screenshots"
    if not os.path.isdir(folder):
        sys.exit(f"Папка «{folder}» не найдена. Создай её и положи туда скриншоты, "
                  f"или укажи путь: python extract_places.py C:\\путь\\к\\папке")

    images = sorted(
        f for f in os.listdir(folder) if f.lower().endswith(SUPPORTED_EXT)
    )
    if not images:
        sys.exit(f"В папке «{folder}» нет изображений ({', '.join(SUPPORTED_EXT)}).")

    print(f"Найдено скриншотов: {len(images)}. Начинаю обработку…\n")
    client = get_client()

    results = []
    all_places = {}  # name -> {"type":..., "count":..., "city":..., "country":...}
    cities_seen = {}

    for i, fname in enumerate(images, 1):
        path = os.path.join(folder, fname)
        print(f"[{i}/{len(images)}] {fname} …", end=" ")
        try:
            data = analyze_image(client, path)
        except json.JSONDecodeError:
            print("не удалось разобрать ответ модели, пропускаю")
            continue
        except Exception as e:
            print(f"ошибка: {e}")
            continue

        places = data.get("places") or []
        city = data.get("city")
        country = data.get("country")
        print(f"нашёл {len(places)} мест" + (f", город: {city}" if city else ""))

        results.append({"file": fname, **data})
        if city:
            cities_seen[city] = cities_seen.get(city, 0) + 1
        for p in places:
            name = (p.get("name") or "").strip()
            if not name:
                continue
            key = name.lower()
            if key not in all_places:
                all_places[key] = {"name": name, "type": p.get("type", "другое"),
                                    "count": 0, "city": city, "country": country}
            all_places[key]["count"] += 1

        time.sleep(1)  # бережём бесплатный лимит запросов в минуту

    # --- Сохраняем результаты ---
    main_city = max(cities_seen, key=cities_seen.get) if cities_seen else None
    places_list = sorted(all_places.values(), key=lambda p: -p["count"])

    with open("places.json", "w", encoding="utf-8") as f:
        json.dump({"city": main_city, "places": places_list, "raw": results},
                   f, ensure_ascii=False, indent=2)

    report_lines = [
        f"Обработано скриншотов: {len(images)} (успешно: {len(results)})",
        f"Определённый город поездки: {main_city or 'не удалось определить'}",
        "",
        f"Найдено уникальных мест: {len(places_list)}",
        "-" * 50,
    ]
    for p in places_list:
        report_lines.append(f"• {p['name']}  [{p['type']}]  — упомянуто {p['count']}×")
        report_lines.append(f"    Карта: {maps_link(p['name'], p['city'])}")
    if main_city:
        report_lines += ["", f"Готовая ссылка на сайт: {site_link(main_city)}"]

    report = "\n".join(report_lines)
    with open("places_report.txt", "w", encoding="utf-8") as f:
        f.write(report)

    print("\n" + "=" * 50)
    print(report)
    print("=" * 50)
    print("\nСохранено: places.json (для кода/бота), places_report.txt (для отправки человеку)")


if __name__ == "__main__":
    main()
