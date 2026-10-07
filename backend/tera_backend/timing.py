"""
قياس زمن الطلبات على الخادم (يُفعَّل بـ REQUEST_TIMING=True فقط).

يسجّل لكل طلب: الطريقة، المسار، رمز الحالة، المدة الكلية، عدد استعلامات
قاعدة البيانات وزمنها — ويضيف ترويسة Server-Timing ليقرأها curl من العميل
فيُفصل زمن الخادم عن زمن الشبكة.
"""

import logging
import time

from django.conf import settings
from django.core.exceptions import MiddlewareNotUsed
from django.db import connections

logger = logging.getLogger("tera.timing")


class RequestTimingMiddleware:
    def __init__(self, get_response):
        if not settings.REQUEST_TIMING:
            raise MiddlewareNotUsed
        self.get_response = get_response

    def __call__(self, request):
        stats = {"queries": 0, "db": 0.0}

        def count(execute, sql, params, many, context):
            started = time.perf_counter()
            try:
                return execute(sql, params, many, context)
            finally:
                stats["queries"] += 1
                stats["db"] += time.perf_counter() - started

        started = time.perf_counter()
        with connections["default"].execute_wrapper(count):
            response = self.get_response(request)
        total_ms = (time.perf_counter() - started) * 1000
        db_ms = stats["db"] * 1000

        logger.info(
            "%s %s %s %.1fms db=%d/%.1fms",
            request.method,
            request.get_full_path(),
            response.status_code,
            total_ms,
            stats["queries"],
            db_ms,
        )
        response["Server-Timing"] = f'app;dur={total_ms:.1f}, db;dur={db_ms:.1f};desc="{stats["queries"]} queries"'
        return response
