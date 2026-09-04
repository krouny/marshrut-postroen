# extract_places.py

Скрипт для быстрого MVP-теста «Волшебник страны Оз»: извлекает названия мест
из скриншотов Instagram/TikTok через Gemini Vision.

## Быстрый старт

```bash
pip install google-genai
```

Получи бесплатный ключ на https://aistudio.google.com/apikey и установи его:

```powershell
$env:GEMINI_API_KEY = "твой_ключ"
```

Положи скриншоты в папку `screenshots/` и запусти:

```bash
python extract_places.py
```

Результат — `places.json` (для кода/бота) и `places_report.txt` (готовые
ссылки на карты, можно сразу переслать пользователю).

Подробности и полный текст промпта — в самом скрипте `extract_places.py`.
