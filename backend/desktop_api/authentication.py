"""
مصادقة Token بصلاحية محدودة المدة.

كان Token الدخول يُنشأ مرة واحدة ويبقى صالحاً للأبد: لو تسرّب من جهاز مسروق أو
موظف سابق لا يتوقف عمله إلا بحذفه يدوياً من الأدمن. الآن يُرفض أي Token لم يُجدَّد
تسجيل الدخول به خلال API_TOKEN_TTL_DAYS يوماً (راجع desktop_login الذي يجدّد
تاريخ الـToken عند كل دخول ناجح، فيمتد للمستخدم النشط فقط).
"""

from datetime import timedelta

from django.conf import settings
from django.utils import timezone
from rest_framework.authentication import TokenAuthentication
from rest_framework.exceptions import AuthenticationFailed


class ExpiringTokenAuthentication(TokenAuthentication):
    def authenticate_credentials(self, key):
        user, token = super().authenticate_credentials(key)
        ttl = timedelta(days=settings.API_TOKEN_TTL_DAYS)
        if token.created + ttl < timezone.now():
            raise AuthenticationFailed("انتهت صلاحية الجلسة، يرجى تسجيل الدخول مجدداً.")
        return user, token
