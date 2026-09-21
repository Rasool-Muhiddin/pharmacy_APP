from django.urls import path

from . import views

urlpatterns = [
    path("health/", views.health, name="health"),
    path("desktop/activate/", views.desktop_activate, name="desktop_activate"),
    path("desktop/login/", views.desktop_login, name="desktop_login"),
    path("desktop/latest-version/", views.desktop_latest_version, name="desktop_latest_version"),
]
