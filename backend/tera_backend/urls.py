from django.contrib import admin
from django.urls import include, path

urlpatterns = [
    path("admin/", admin.site.urls),
    path("api/", include("desktop_api.urls")),
    path("api/", include("pharmacy_data.urls")),
]