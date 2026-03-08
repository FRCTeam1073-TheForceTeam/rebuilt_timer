.PHONY: help
help:
	@echo "Available targets:"
	@echo "  build-web          Build Flutter web application"
	@echo "  build-android      Build Flutter Android release APK"
	@echo "  release-web        Copy web build to ~/sites/viperscout.com/www/rebuilt-timer/"
	@echo "  release-android    Copy Android APK to ~/sites/viperscout.com/www/rebuilt-timer.apk"
	@echo "  build              Build both web and android"
	@echo "  release            Release both web and android"
	@echo "  clean              Clean build artifacts"

.PHONY: build-web
build-web:
	@echo "Building Flutter web..."
	flutter build web --release --base-href=/rebuilt-timer/

.PHONY: build-android
build-android:
	@echo "Building Flutter Android release APK..."
	flutter build apk --release

.PHONY: release-web
release-web: build-web
	@echo "Releasing web to ~/sites/viperscout.com/www/rebuilt-timer/"
	cp -r build/web/* ~/sites/viperscout.com/www/rebuilt-timer/

.PHONY: release-android
release-android: build-android
	@echo "Releasing Android APK to ~/sites/viperscout.com/www/rebuilt-timer.apk"
	cp -v ./build/app/outputs/flutter-apk/app-release.apk ~/sites/viperscout.com/www/rebuilt-timer.apk

.PHONY: build
build: build-web build-android
	@echo "Build complete: web and android"

.PHONY: release
release: release-web release-android
	@echo "Release complete: web and android"

.PHONY: clean
clean:
	@echo "Cleaning build artifacts..."
	flutter clean
