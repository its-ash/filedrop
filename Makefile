STORE_ID := filedrop
APP_DIR := flutter

RUST_ANDROID := cd rust && cargo ndk -t arm64-v8a -t x86_64 -o ../flutter/android/app/src/main/jniLibs build --release -p filedrop-ffi

.PHONY: run build clean

run:
	$(RUST_ANDROID) && cd ../flutter && flutter run -d android

build:
	$(RUST_ANDROID) && cd ../flutter && flutter build apk --release

clean:
	cd flutter && flutter clean
	rm -rf dist

# deploy, release, bump, store-check, store-meta, version
include store.mk
