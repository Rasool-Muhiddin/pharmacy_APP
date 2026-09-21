# Tera Desktop Backend

هذا Backend مستقل لتطبيق سطح المكتب فقط. لا يقرأ من `E:\\TEST\\tera_COMP` ولا يكتب فيه ولا يشارك قاعدة بياناته أو أسراره.

## التشغيل المحلي

1. ثبّت Python 3.12 أو أحدث.
2. من هذا المجلد: `python -m venv .venv`
3. فعّل البيئة: `.venv\\Scripts\\Activate.ps1`
4. ثبّت الحزم: `pip install -r requirements.txt`
5. انسخ `.env.example` إلى `.env` واضبط `DEBUG=True` للتطوير فقط.
6. نفّذ: `python manage.py migrate`
7. أنشئ حساب الإدارة: `python manage.py createsuperuser`
8. شغّل: `python manage.py runserver`

فحص الصحة: `http://127.0.0.1:8000/api/health/`

## واجهات التطبيق الحالية

- `POST /api/desktop/activate/`
- `POST /api/desktop/login/`
- `GET /api/desktop/latest-version/`

تطابق هذه الواجهات احتياج نسخة Flutter الحالية للتفعيل وتسجيل الدخول وفحص التحديث. واجهات مزامنة بيانات المخزون والمبيعات للوضع الأونلاين ستضاف بصورة مستقلة قبل ربط أي جهاز إنتاج بالخادم.

لبناء Flutter على خادم الـBackend الجديد، استخدم مثلاً:

`flutter build windows --dart-define=TERA_API_BASE_URL=https://api.example.com/api/desktop`

الرابط الافتراضي في كود التطوير هو `http://127.0.0.1:8000/api/desktop`. عند بناء نسخة العملاء مرّر دائماً رابط خادم الإنتاج بواسطة `--dart-define`.

## النشر

استخدم PostgreSQL مع `DATABASE_URL` و`DEBUG=False` و`SECRET_KEY` قوي و`ALLOWED_HOSTS` مضبوط. لا تضع ملف `.env` أو قاعدة البيانات أو مفاتيح النشر في Git.
